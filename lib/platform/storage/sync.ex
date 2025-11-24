defmodule Platform.Storage.Sync do
  @moduledoc "Storage sync (local, in-process) lifecycle and status"

  require Logger

  @key {__MODULE__, :status}

  @type state :: :inactive | :active | :done | {:error, term()}

  @spec enabled?() :: boolean()
  def enabled? do
    config() |> Keyword.get(:enabled, true)
  end

  @spec schemas(keyword()) :: [atom() | String.t()]
  def schemas(opts \\ []) do
    default = Keyword.get(opts, :default, [:users])
    config() |> Keyword.get(:schemas, default)
  end

  @spec status() :: %{state: state}
  def status do
    %{state: :persistent_term.get(@key, :inactive)}
  end

  @spec set_active() :: :ok
  def set_active do
    :persistent_term.put(@key, :active)
    Logger.info("[storage.sync] state=active")
    :ok
  end

  @spec set_done() :: :ok
  def set_done do
    :persistent_term.put(@key, :done)
    Logger.info("[storage.sync] state=done")
    :ok
  end

  @spec set_error(term()) :: :ok
  def set_error(reason) do
    :persistent_term.put(@key, {:error, reason})
    Logger.error("[storage.sync] state=error reason=#{inspect(reason)}")
    :ok
  end

  @spec run_local_sync(keyword()) :: :ok | {:error, term()}
  def run_local_sync(opts) do
    source = Keyword.get(opts, :source_repo)
    target = Keyword.get(opts, :target_repo)
    schemas = Keyword.get(opts, :schemas, schemas())

    Logger.info("[storage.sync] local in-process sync start source=#{inspect(source)} target=#{inspect(target)} schemas=#{inspect(schemas)}")

    # Placeholder: Real row-level sync is provided by Chat/ElectricSQL.
    # The bootstrap copy has already completed at this point.
    :ok
  rescue
    e ->
      set_error(e)
      {:error, e}
  end

  defp config do
    Application.get_env(:platform, __MODULE__, [])
  end
end
