defmodule Platform.App.Media.Decider do
  use GenServer

  require Logger

  def start_link(args) do
    GenServer.start_link(__MODULE__, args, [])
  end

  @impl GenServer
  def init([device]) do
    "Platform.App.Media.Decider start" |> Logger.info()

    {:ok, device, {:continue, :choose_functionality}}
  end

  @impl GenServer
  def handle_continue(:choose_functionality, device) do
    "Platform.App.Media.Decider starting functionality" |> Logger.info()

    Platform.App.Media.FunctionalityDynamicSupervisor
    |> DynamicSupervisor.start_child({Platform.App.Db.BackupDbSupervisor, [device]})

    {:noreply, device}
  end
end
