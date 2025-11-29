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

  use OriginLog

  # Batch size for insert_all operations
  @batch_size 500

  @type repo :: module()
  @type schema :: atom()
  @type sync_opts :: [
          source_repo: repo(),
          target_repo: repo(),
          schemas: [schema()],
          batch_size: pos_integer()
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
  - `:schemas` - List of schema atoms to sync (default: `[:users]`)
  - `:batch_size` - Number of rows per batch insert (default: #{@batch_size})
  """
  @spec sync(sync_opts()) :: {:ok, map()} | {:error, term()}
  def sync(opts) do
    source_repo = Keyword.fetch!(opts, :source_repo)
    target_repo = Keyword.fetch!(opts, :target_repo)
    schemas = Keyword.get(opts, :schemas, [:users])
    batch_size = Keyword.get(opts, :batch_size, @batch_size)

    log(
      "starting sync source=#{inspect(source_repo)} target=#{inspect(target_repo)} schemas=#{inspect(schemas)}",
      :info
    )

    start_time = System.monotonic_time(:millisecond)

    result =
      Enum.reduce_while(schemas, {:ok, %{}}, fn schema, {:ok, acc} ->
        case sync_schema(source_repo, target_repo, schema, batch_size) do
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
  defp sync_schema(source_repo, target_repo, :users, batch_size) do
    # For users table, use pub_key as the identifier
    sync_table(source_repo, target_repo, Chat.Data.Schemas.User, :pub_key, batch_size)
  end

  defp sync_schema(_source_repo, _target_repo, schema, _batch_size) do
    log("schema #{schema} not yet supported, skipping", :warning)
    {:ok, 0}
  end

  # Generic table sync using a specific identifier field
  defp sync_table(source_repo, target_repo, schema_module, id_field, batch_size) do
    import Ecto.Query

    # Get all IDs from source
    source_ids =
      source_repo.all(from(s in schema_module, select: field(s, ^id_field)))
      |> MapSet.new()

    # Get all IDs from target
    target_ids =
      target_repo.all(from(t in schema_module, select: field(t, ^id_field)))
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
        case sync_batch(source_repo, target_repo, schema_module, id_field, batch_ids) do
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
  defp sync_batch(source_repo, target_repo, schema_module, id_field, batch_ids) do
    import Ecto.Query

    # Fetch full rows from source for this batch
    rows =
      source_repo.all(
        from(s in schema_module,
          where: field(s, ^id_field) in ^batch_ids
        )
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

    # Batch insert with ON CONFLICT DO NOTHING
    # This is the CRDT-like behavior: existing rows are preserved
    case insert_all_safe(target_repo, schema_module, entries) do
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
  defp insert_all_safe(_repo, _schema_module, entries) when entries == [] do
    {:ok, 0}
  end

  defp insert_all_safe(repo, schema_module, entries) do
    # Use insert_all with on_conflict: :nothing for CRDT-like behavior
    # conflict_target specifies which columns to check for conflicts
    {count, _} =
      repo.insert_all(
        schema_module,
        entries,
        on_conflict: :nothing,
        conflict_target: conflict_target(schema_module)
      )

    {:ok, count}
  rescue
    e in Postgrex.Error ->
      {:error, e}

    e ->
      {:error, e}
  end

  # Get the conflict target (primary key) for a schema
  defp conflict_target(Chat.Data.Schemas.User), do: [:pub_key]
  defp conflict_target(_schema), do: [:id]

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
end
