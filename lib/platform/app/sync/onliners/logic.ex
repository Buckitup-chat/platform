defmodule Platform.App.Sync.Onliners.Logic do
  @moduledoc """
  Gathers keys from the online users and starts the sync process.
  """

  use GenServer

  require Logger

  alias Chat.Db.Scope.KeyScope
  alias Platform.App.Sync.Onliners.OnlinersDynamicSupervisor
  alias Platform.Storage.Backup.{Copier, Stopper}

  def start_link(args) do
    GenServer.start_link(__MODULE__, args, [])
  end

  @impl GenServer
  def init(tasks_name) do
    "Platform.App.Sync.Onliners.Logic start" |> Logger.info()

    {:ok, [keys: MapSet.new(), tasks_name: tasks_name], {:continue, :start_sync}}
  end

  @impl GenServer
  def handle_continue(:start_sync, state) do
    "Platform.App.Sync.Onliners.Logic starting sync" |> Logger.info()

    Process.send_after(self(), :do_sync, 5000)

    {:noreply, state}
  end

  @impl GenServer
  def handle_info(:do_sync, state) do
    "Platform.App.Sync.Onliners.Logic syncing" |> Logger.info()

    keys = KeyScope.get_keys(Chat.Db.db(), state[:keys])
    opts = Keyword.put(state, :keys, keys)

    OnlinersDynamicSupervisor
    |> DynamicSupervisor.start_child({Copier, opts})

    OnlinersDynamicSupervisor
    |> DynamicSupervisor.start_child(Stopper)

    {:noreply, state}
  end

  def handle_info({:user_keys, user_keys}, state) do
    keys =
      state
      |> Keyword.get(:keys)
      |> MapSet.union(user_keys)

    KeyScope

    {:noreply, Keyword.put(state, :keys, keys)}
  end
end
