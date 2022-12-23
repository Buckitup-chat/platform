defmodule Platform.Storage.Backup.Stopper do
  @moduledoc """
  Awaits few seconds and finalizing copying
  """
  use GenServer

  require Logger

  def start_link(args) do
    GenServer.start_link(__MODULE__, args, [])
  end

  @impl true
  def init(args) do
    Logger.info("starting #{__MODULE__}")
    Process.flag(:trap_exit, true)
    {:ok, on_start(args)}
  end

  # handle the trapped exit call
  @impl true
  def handle_info({:EXIT, _from, reason}, state) do
    Logger.info("exiting #{__MODULE__}")
    cleanup(reason, state)
    {:stop, reason, state}
  end

  # handle termination
  @impl true
  def terminate(reason, state) do
    Logger.info("terminating #{__MODULE__}")
    cleanup(reason, state)
    state
  end

  defp on_start(args) do
    Process.sleep(5_000)
    Logger.info("backup finished. Stopping supervisor")

    DynamicSupervisor.terminate_child(
      Platform.BackupDbSupervisor,
      Platform.App.Db.BackupDbSupervisor |> Process.whereis()
    )

    args
  end

  defp cleanup(reason, _state) do
    reason
  end
end
