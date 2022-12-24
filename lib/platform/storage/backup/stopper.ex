defmodule Platform.Storage.Backup.Stopper do
  @moduledoc """
  Awaits few seconds and finalizing copying
  """
  use GenServer

  require Logger
  alias Platform.Leds

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

  def handle_info(:stop_supervisor, state) do
    DynamicSupervisor.terminate_child(
      Platform.BackupDbSupervisor,
      Platform.App.Db.BackupDbSupervisor |> Process.whereis()
    )

    {:noreply, state}
  end

  # handle termination
  @impl true
  def terminate(reason, state) do
    Logger.info("terminating #{__MODULE__}")
    cleanup(reason, state)
    state
  end

  defp on_start(args) do
    Leds.blink_dump()
    Process.sleep(5_000)
    Logger.info("backup finished. Stopping supervisor")

    Process.send_after(self(), :stop_supervisor, 5_000)

    args
  end

  defp cleanup(reason, _state) do
    Leds.blink_done()
    reason
  end
end
