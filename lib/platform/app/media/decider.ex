defmodule Platform.App.Media.Decider do
  use GenServer

  require Logger

  def start_link(args) do
    GenServer.start_link(__MODULE__, args, [])
  end

  @impl GenServer
  def init([device]) do
    "Platform.App.Media.Decider start" |> Logger.info()

    Platform.App.Media.FunctionalityDynamicSupervisor
    |> DynamicSupervisor.start_child({Platform.App.Db.BackupDbSupervisor, [device]})

    {:ok, nil}
  end
end
