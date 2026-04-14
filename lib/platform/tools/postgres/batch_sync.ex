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

  Table-level sync operations are in `Platform.Tools.Postgres.BatchSync.TableSync`.
  """

  use Toolbox.OriginLog

  alias __MODULE__.TableSync

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

  # Schema routing

  defp sync_schema(source_repo, target_repo, :user_cards, batch_size, config) do
    TableSync.sync_table(source_repo, target_repo, Chat.Data.Schemas.UserCard, batch_size, config)
  end

  defp sync_schema(source_repo, target_repo, :user_storage, batch_size, config) do
    TableSync.sync_table(
      source_repo,
      target_repo,
      Chat.Data.Schemas.UserStorage,
      batch_size,
      config
    )
  end

  defp sync_schema(source_repo, target_repo, :user_storage_versions, batch_size, config) do
    TableSync.sync_table(
      source_repo,
      target_repo,
      Chat.Data.Schemas.UserStorageVersion,
      batch_size,
      config
    )
  end

  defp sync_schema(_source_repo, _target_repo, schema, _batch_size, _config) do
    log("schema #{schema} not yet supported, skipping", :warning)
    {:ok, 0}
  end

  # Schema configuration with defaults

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
end
