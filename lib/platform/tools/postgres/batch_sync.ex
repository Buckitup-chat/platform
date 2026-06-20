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
  @type conflict_strategy :: :nothing | :replace_all | {:update, [atom()]}
  @type schema_config :: %{
          id_field: atom() | [atom()],
          conflict_target: [atom()],
          on_conflict: conflict_strategy()
        }
  @type sync_opts :: [
          source_repo: repo(),
          target_repo: repo(),
          schemas: [module()],
          batch_size: pos_integer(),
          schema_config: %{module() => schema_config()}
        ]

  @doc """
  Performs unidirectional sync from source to target for the given Ecto schemas.

  For each schema module:
  1. Fetch all primary keys from source and target
  2. Compute set difference to find missing keys
  3. Batch-copy missing rows from source to target

  Returns `{:ok, stats}` with row counts per schema, or `{:error, reason}`.

  ## Options

  - `:source_repo` - Source Ecto repo (required)
  - `:target_repo` - Target Ecto repo (required)
  - `:schemas` - List of Ecto schema modules to sync (default: `Chat.Data.Shapes.sync_schemas()`)
  - `:batch_size` - Number of rows per batch insert (default: #{@batch_size})
  - `:schema_config` - Per-module configuration map (optional, overrides auto-detected primary keys)

  Primary keys and conflict targets are derived automatically from each schema's
  `__schema__(:primary_key)`. Custom conflict resolution can be provided via `:schema_config`:

      %{
        Chat.Data.Schemas.UserCard => %{
          on_conflict: :replace_all
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
    schemas = Keyword.get(opts, :schemas, Platform.Storage.Sync.schemas())
    batch_size = Keyword.get(opts, :batch_size, @batch_size)
    schema_config = Keyword.get(opts, :schema_config, %{})

    log(
      "starting sync source=#{inspect(source_repo)} target=#{inspect(target_repo)} schemas=#{inspect(schemas)}",
      :info
    )

    start_time = System.monotonic_time(:millisecond)

    result =
      Enum.reduce_while(schemas, {:ok, %{}}, fn schema_module, {:ok, acc} ->
        config = config_for(schema_module, schema_config)

        case TableSync.sync_table(source_repo, target_repo, schema_module, batch_size, config) do
          {:ok, count} ->
            {:cont, {:ok, Map.put(acc, schema_module, count)}}

          {:error, reason} = error ->
            log("failed to sync schema=#{inspect(schema_module)} reason=#{inspect(reason)}", :error)
            {:halt, error}
        end
      end)

    duration = System.monotonic_time(:millisecond) - start_time

    case result do
      {:ok, stats} ->
        total = stats |> Map.values() |> Enum.sum()
        log("sync complete stats=#{inspect(stats)} total_rows=#{total} duration_ms=#{duration}", :info)
        {:ok, stats}

      error ->
        error
    end
  end

  defp config_for(schema_module, custom_config) do
    primary_key_fields = Chat.Data.Shapes.primary_key(schema_module)

    default =
      case primary_key_fields do
        [single] ->
          %{id_field: single, conflict_target: [single], on_conflict: :nothing}

        multiple ->
          %{id_field: multiple, conflict_target: multiple, on_conflict: :nothing}
      end

    Map.merge(default, Map.get(custom_config, schema_module, %{}))
  end
end
