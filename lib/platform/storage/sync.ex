defmodule Platform.Storage.Sync do
  @moduledoc "Storage sync (local, in-process) lifecycle and status"

  use OriginLog

  @key {__MODULE__, :status}

  @type state :: :inactive | :active | :done | {:error, term()}

  @spec schemas(keyword()) :: [atom() | String.t()]
  def schemas(opts \\ []) do
    default = Keyword.get(opts, :default, [:users])
    # If schemas is configured, use it; otherwise use the provided default
    case config() |> Keyword.get(:schemas) do
      nil -> default
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
    :persistent_term.put(@key, :done)
    log("state=done", :info)
    :ok
  end

  @spec set_error(term()) :: :ok
  def set_error(reason) do
    :persistent_term.put(@key, {:error, reason})
    log("state=error reason=#{inspect(reason)}", :error)
    :ok
  end

  @spec run_local_sync(keyword()) :: :ok | {:error, term()}
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
