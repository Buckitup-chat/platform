defmodule Platform.Tools.Postgres.BatchSync do
  @moduledoc """
  Optimized PostgreSQL synchronization using batch operations.

  This module provides efficient diff+copy implementation for syncing data
  between internal and main PostgreSQL clusters. It uses:
  - Set-based diffing for identifying missing rows
  - Batch inserts with `insert_all` for performance
  - `ON CONFLICT DO NOTHING` for CRDT-like conflict resolution

  Direction is determined by the current mode:
  - `:internal_to_main` - sync from internal → main
  - `:main_to_internal` - sync from main → internal

  ## Performance Optimizations

  1. **Batch inserts**: Uses `Repo.insert_all/3` instead of individual inserts
  2. **Chunked processing**: Fetches data in batches to avoid memory pressure
  3. **Conflict resolution**: Uses PostgreSQL's `ON CONFLICT DO NOTHING`
  """

  use Toolbox.OriginLog

  import Ecto.Query

  # Batch size for insert_all operations
  @batch_size 500

  @type repo :: module()
  @type schema :: atom()
  @type conflict_strategy :: :nothing | :replace_all | {:update, [atom()]}
  @type schema_config :: %{
          id_field: atom(),
          conflict_target: [atom()],
          on_conflict: conflict_strategy()
        }
  @type sync_opts :: [
          source_repo: repo(),
          target_repo: repo(),
          schemas: [schema()],
          batch_size: pos_integer(),
          schema_config: %{schema() => schema_config()}
        ]

  @doc """
  Performs unidirectional sync from source to target for the given schemas.

  For each schema:
  1. Fetch all primary keys from source and target
  2. Compute set difference to find missing keys
  3. Batch-copy missing rows from source to target

  Returns `{:ok, stats}` with row counts per schema, or `{:error, reason}`.

  ## Options

  - `:source_repo` - Source Ecto repo (required)
  - `:target_repo` - Target Ecto repo (required)
  - `:schemas` - List of schema atoms to sync (default: `[]`)
  - `:batch_size` - Number of rows per batch insert (default: #{@batch_size})
  - `:schema_config` - Per-schema configuration map (optional)

  ## Schema Configuration

  Each schema can have custom conflict resolution:

      %{
        users: %{
          id_field: :pub_key,
          conflict_target: [:pub_key],
          on_conflict: :nothing  # or :replace_all or {:update, [:name, :updated_at]}
        }
      }

  Conflict strategies:
  - `:nothing` - Skip conflicting rows (CRDT-like, default)
  - `:replace_all` - Replace entire row on conflict
  - `{:update, fields}` - Update only specified fields on conflict
  """
  @spec sync(sync_opts()) :: {:ok, map()} | {:error, term()}
  def sync(opts) do
    source_repo = Keyword.fetch!(opts, :source_repo)
    target_repo = Keyword.fetch!(opts, :target_repo)
    schemas = Keyword.get(opts, :schemas, [:user_cards, :user_storage, :user_storage_versions])
    batch_size = Keyword.get(opts, :batch_size, @batch_size)
    schema_config = Keyword.get(opts, :schema_config, %{})

    log(
      "starting sync source=#{inspect(source_repo)} target=#{inspect(target_repo)} schemas=#{inspect(schemas)}",
      :info
    )

    start_time = System.monotonic_time(:millisecond)

    result =
      Enum.reduce_while(schemas, {:ok, %{}}, fn schema, {:ok, acc} ->
        config = get_schema_config(schema, schema_config)

        case sync_schema(source_repo, target_repo, schema, batch_size, config) do
          {:ok, count} ->
            {:cont, {:ok, Map.put(acc, schema, count)}}

          {:error, reason} = error ->
            log(
              "failed to sync schema=#{schema} reason=#{inspect(reason)}",
              :error
            )

            {:halt, error}
        end
      end)

    duration = System.monotonic_time(:millisecond) - start_time

    case result do
      {:ok, stats} ->
        total = stats |> Map.values() |> Enum.sum()

        log(
          "sync complete stats=#{inspect(stats)} total_rows=#{total} duration_ms=#{duration}",
          :info
        )

        {:ok, stats}

      error ->
        error
    end
  end

  # Sync a single schema from source to target
  defp sync_schema(source_repo, target_repo, :user_cards, batch_size, config) do
    sync_table(source_repo, target_repo, Chat.Data.Schemas.UserCard, batch_size, config)
  end

  defp sync_schema(source_repo, target_repo, :user_storage, batch_size, config) do
    sync_table(source_repo, target_repo, Chat.Data.Schemas.UserStorage, batch_size, config)
  end

  defp sync_schema(source_repo, target_repo, :user_storage_versions, batch_size, config) do
    sync_table(source_repo, target_repo, Chat.Data.Schemas.UserStorageVersion, batch_size, config)
  end

  defp sync_schema(_source_repo, _target_repo, schema, _batch_size, _config) do
    log("schema #{schema} not yet supported, skipping", :warning)
    {:ok, 0}
  end

  # Get schema configuration with defaults
  defp get_schema_config(:user_cards, custom_config) do
    default = %{
      id_field: :user_hash,
      conflict_target: [:user_hash],
      on_conflict: :nothing
    }

    Map.merge(default, Map.get(custom_config, :user_cards, %{}))
  end

  defp get_schema_config(:user_storage, custom_config) do
    default = %{
      id_field: [:user_hash, :uuid],
      conflict_target: [:user_hash, :uuid],
      on_conflict: :nothing
    }

    Map.merge(default, Map.get(custom_config, :user_storage, %{}))
  end

  defp get_schema_config(:user_storage_versions, custom_config) do
    default = %{
      id_field: [:user_hash, :uuid, :sign_hash],
      conflict_target: [:user_hash, :uuid, :sign_hash],
      on_conflict: :nothing
    }

    Map.merge(default, Map.get(custom_config, :user_storage_versions, %{}))
  end

  defp get_schema_config(schema, custom_config) do
    default = %{
      id_field: :id,
      conflict_target: [:id],
      on_conflict: :nothing
    }

    Map.merge(default, Map.get(custom_config, schema, %{}))
  end

  # Generic table sync using a specific identifier field
  defp sync_table(source_repo, target_repo, schema_module, batch_size, config) do
    import Ecto.Query

    id_field = config.id_field

    # Get all IDs from source
    source_ids =
      source_repo.all(build_select_query(schema_module, id_field))
      |> MapSet.new()

    # Get all IDs from target
    target_ids =
      target_repo.all(build_select_query(schema_module, id_field))
      |> MapSet.new()

    # Find missing IDs (in source but not in target)
    missing_ids = MapSet.difference(source_ids, target_ids)
    missing_count = MapSet.size(missing_ids)

    if missing_count == 0 do
      log("no missing rows for #{inspect(schema_module)}", :debug)
      {:ok, 0}
    else
      log(
        "syncing #{missing_count} missing rows for #{inspect(schema_module)}",
        :info
      )

      # Fetch and insert in batches
      missing_ids
      |> MapSet.to_list()
      |> Stream.chunk_every(batch_size)
      |> Enum.reduce_while({:ok, 0}, fn batch_ids, {:ok, total} ->
        case sync_batch(source_repo, target_repo, schema_module, batch_ids, config) do
          {:ok, count} ->
            {:cont, {:ok, total + count}}

          {:error, _} = error ->
            {:halt, error}
        end
      end)
    end
  rescue
    e ->
      log(
        "exception during sync schema=#{inspect(schema_module)} error=#{inspect(e)}",
        :error
      )

      {:error, e}
  end

  # Sync a batch of rows
  defp sync_batch(source_repo, target_repo, schema_module, batch_ids, config) do
    import Ecto.Query

    id_field = config.id_field

    # Fetch full rows from source for this batch
    rows =
      source_repo.all(
        build_where_query(schema_module, id_field, batch_ids)
      )

    # Convert structs to maps for insert_all
    # Filter to only include database fields (exclude virtual fields)
    db_fields = schema_module.__schema__(:fields)

    entries =
      Enum.map(rows, fn row ->
        row
        |> Map.from_struct()
        |> Map.take(db_fields)
        |> maybe_add_timestamps(schema_module)
      end)

    # Batch insert with configurable conflict resolution
    case insert_all_safe(target_repo, schema_module, entries, config) do
      {:ok, count} ->
        {:ok, count}

      {:error, reason} ->
        log(
          "batch insert failed reason=#{inspect(reason)}",
          :error
        )

        {:error, reason}
    end
  end

  # Safe wrapper for insert_all that handles conflicts
  defp insert_all_safe(_repo, _schema_module, entries, _config) when entries == [] do
    {:ok, 0}
  end

  defp insert_all_safe(repo, schema_module, entries, config) do
    # Build insert options based on conflict strategy
    opts = build_insert_opts(config)

    {count, _} = repo.insert_all(schema_module, entries, opts)

    {:ok, count}
  rescue
    e in Postgrex.Error ->
      {:error, e}

    e ->
      {:error, e}
  end

  # Build insert_all options based on conflict configuration
  defp build_insert_opts(config) do
    base_opts = [conflict_target: config.conflict_target]

    case config.on_conflict do
      :nothing ->
        # CRDT-like: skip conflicting rows
        Keyword.put(base_opts, :on_conflict, :nothing)

      :replace_all ->
        # Replace entire row on conflict
        Keyword.put(base_opts, :on_conflict, :replace_all)

      {:update, fields} when is_list(fields) ->
        # Update only specified fields on conflict
        Keyword.put(base_opts, :on_conflict, {:replace, fields})

      _ ->
        # Default to :nothing for unknown strategies
        Keyword.put(base_opts, :on_conflict, :nothing)
    end
  end

  # Add timestamps if the schema has them but they're nil
  defp maybe_add_timestamps(attrs, schema_module) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    attrs
    |> maybe_put_timestamp(:inserted_at, now, schema_module)
    |> maybe_put_timestamp(:updated_at, now, schema_module)
  end

  defp maybe_put_timestamp(attrs, field, value, schema_module) do
    if has_field?(schema_module, field) and is_nil(Map.get(attrs, field)) do
      Map.put(attrs, field, value)
    else
      attrs
    end
  end

  defp has_field?(schema_module, field) do
    field in schema_module.__schema__(:fields)
  end

  # Build select query for single or composite primary key
  defp build_select_query(schema_module, id_field) when is_atom(id_field) do
    from(s in schema_module, select: field(s, ^id_field))
  end

  defp build_select_query(schema_module, id_fields) when is_list(id_fields) do
    # For composite keys, select all fields as a tuple
    case id_fields do
      [field1, field2] ->
        from(s in schema_module, select: {field(s, ^field1), field(s, ^field2)})

      [field1, field2, field3] ->
        from(s in schema_module,
          select: {field(s, ^field1), field(s, ^field2), field(s, ^field3)}
        )

      _ ->
        # Fallback for other composite key sizes
        raise "Composite keys with #{length(id_fields)} fields not yet supported"
    end
  end

  # Build where query for single or composite primary key
  defp build_where_query(schema_module, id_field, batch_ids) when is_atom(id_field) do
    from(s in schema_module,
      where: field(s, ^id_field) in ^batch_ids
    )
  end

  defp build_where_query(schema_module, id_fields, batch_ids) when is_list(id_fields) do
    # For composite keys, batch_ids is a list of tuples
    # Build OR conditions for each tuple
    Enum.reduce(batch_ids, from(s in schema_module, where: false), fn id_tuple, query ->
      conditions =
        id_fields
        |> Enum.zip(Tuple.to_list(id_tuple))
        |> Enum.map(fn {field, value} ->
          dynamic([s], field(s, ^field) == ^value)
        end)
        |> Enum.reduce(&dynamic([s], ^&1 and ^&2))

      from(s in query, or_where: ^conditions)
    end)
  end
end
