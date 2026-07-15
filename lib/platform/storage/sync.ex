defmodule Platform.Storage.Sync do
  @moduledoc "Storage sync (local, in-process) lifecycle and status"

  use Toolbox.OriginLog

  @key {__MODULE__, :status}

  @type state :: :inactive | :active | :done | {:partial, map()} | {:error, term()}

  @spec schemas(keyword()) :: [module()]
  def schemas(opts \\ []) do
    case config() |> Keyword.get(:schemas) do
      nil -> Keyword.get(opts, :default, Chat.Data.Shapes.sync_schemas())
      configured -> configured
    end
  end

  @spec status() :: %{state: state}
  def status do
    %{state: :persistent_term.get(@key, :inactive)}
  end

  @spec set_active() :: :ok
  def set_active do
    :persistent_term.put(@key, :active)
    log("state=active", :info)
    :ok
  end

  @spec set_done() :: :ok
  def set_done do
    # Never downgrade a recorded failure to "done" — a partial or aborted sync must
    # stay visible. set_active/0 resets the status at the start of each attempt.
    case :persistent_term.get(@key, :inactive) do
      {:error, _} = status ->
        log("keeping state=#{inspect(status)} (not overwriting with done)", :warning)
        :ok

      {:partial, _} = status ->
        log("keeping state=#{inspect(status)} (not overwriting with done)", :warning)
        :ok

      _ ->
        :persistent_term.put(@key, :done)
        log("state=done", :info)
        :ok
    end
  end

  @spec set_partial(map()) :: :ok
  def set_partial(failures) do
    :persistent_term.put(@key, {:partial, failures})
    log("state=partial failed=#{inspect(Map.keys(failures))}", :warning)
    :ok
  end

  @spec set_error(term()) :: :ok
  def set_error(reason) do
    :persistent_term.put(@key, {:error, reason})
    log("state=error reason=#{inspect(reason)}", :error)
    :ok
  end

  @spec run_local_sync(keyword()) :: :ok | {:partial, map()} | {:error, term()}
  def run_local_sync(opts) do
    source = Keyword.get(opts, :source_repo)
    target = Keyword.get(opts, :target_repo)
    schemas = Keyword.get(opts, :schemas, schemas())

    log(
      "local in-process sync start source=#{inspect(source)} target=#{inspect(target)} schemas=#{inspect(schemas)}",
      :info
    )

    # Perform unidirectional diff+copy using BatchSync
    case Platform.Tools.Postgres.BatchSync.sync(
           source_repo: source,
           target_repo: target,
           schemas: schemas
         ) do
      {:ok, stats} ->
        log("sync complete stats=#{inspect(stats)}", :info)
        :ok

      {:partial, stats, failures} ->
        set_partial(failures)

        log(
          "sync partial stats=#{inspect(stats)} failed=#{inspect(Map.keys(failures))}",
          :warning
        )

        {:partial, failures}

      {:error, reason} = error ->
        set_error(reason)
        log("sync failed reason=#{inspect(reason)}", :error)
        error
    end
  rescue
    e ->
      set_error(e)
      {:error, e}
  end

  defp config do
    Application.get_env(:platform, __MODULE__, [])
  end
end
