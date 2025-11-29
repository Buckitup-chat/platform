defmodule Platform.Tools.Postgres.ElectricSync do
  @moduledoc """
  Wrapper for performing unidirectional PostgreSQL synchronization.

  This module provides a minimal diff+copy implementation for syncing data
  between internal and main PostgreSQL clusters. It compares rows by primary
  keys and copies missing rows from source to target.

  Direction is determined by the current mode:
  - `:internal_to_main` - sync from internal → main
  - `:main_to_internal` - sync from main → internal
  """

  use OriginLog

  @type repo :: module()
  @type schema :: atom()
  @type sync_opts :: [
          source_repo: repo(),
          target_repo: repo(),
          schemas: [schema()]
        ]

  @doc """
  Performs unidirectional sync from source to target for the given schemas.

  For each schema:
  1. Fetch all primary keys from source
  2. Fetch all primary keys from target
  3. Identify missing keys (present in source, absent in target)
  4. Copy missing rows from source to target

  Returns `{:ok, stats}` with row counts per schema, or `{:error, reason}`.
  """
  @spec sync(sync_opts()) :: {:ok, map()} | {:error, term()}
  def sync(opts) do
    source_repo = Keyword.fetch!(opts, :source_repo)
    target_repo = Keyword.fetch!(opts, :target_repo)
    schemas = Keyword.get(opts, :schemas, [:users])

    log(
      "starting sync source=#{inspect(source_repo)} target=#{inspect(target_repo)} schemas=#{inspect(schemas)}",
      :info
    )

    start_time = System.monotonic_time(:millisecond)

    result =
      Enum.reduce_while(schemas, {:ok, %{}}, fn schema, {:ok, acc} ->
        case sync_schema(source_repo, target_repo, schema) do
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
  defp sync_schema(source_repo, target_repo, :users) do
    # For users table, use pub_key as the identifier
    sync_table(source_repo, target_repo, Chat.Data.Schemas.User, :pub_key)
  end

  defp sync_schema(_source_repo, _target_repo, schema) do
    log("schema #{schema} not yet supported, skipping", :warning)
    {:ok, 0}
  end

  # Generic table sync using a specific identifier field
  defp sync_table(source_repo, target_repo, schema_module, id_field) do
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

    if MapSet.size(missing_ids) == 0 do
      log(
        "no missing rows for #{inspect(schema_module)}",
        :debug
      )

      {:ok, 0}
    else
      # Fetch full rows from source for missing IDs
      missing_rows =
        source_repo.all(
          from(s in schema_module,
            where: field(s, ^id_field) in ^MapSet.to_list(missing_ids)
          )
        )

      # Insert into target (ON CONFLICT DO NOTHING to preserve existing)
      count =
        Enum.reduce_while(missing_rows, 0, fn row, acc ->
          # Convert struct to map and remove metadata
          attrs =
            row
            |> Map.from_struct()
            |> Map.drop([:__meta__])

          changeset = schema_module.changeset(struct(schema_module), attrs)

          case target_repo.insert(changeset, on_conflict: :nothing) do
            {:ok, _} ->
              {:cont, acc + 1}

            {:error, reason} ->
              {:halt, {:error, reason}}
          end
        end)

      case count do
        {:error, _} = error -> error
        n when is_integer(n) -> {:ok, n}
      end
    end
  rescue
    e ->
      log(
        "exception during sync schema=#{inspect(schema_module)} error=#{inspect(e)}",
        :error
      )

      {:error, e}
  end
end
