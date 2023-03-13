defmodule Platform.App.Sync.Onliners.Logic do
  @moduledoc """
  Gathers keys from the online users and starts the sync process.
  """

  use GenServer

  require Logger

  alias Chat.Db.Scope.KeyScope
  alias Phoenix.PubSub
  alias Platform.App.Sync.Onliners.OnlinersDynamicSupervisor
  alias Platform.Storage.Onliners.{Copier, Stopper}

  @incoming_topic "chat_onliners->platform_onliners"
  @outgoing_topic "platform_onliners->chat_onliners"

  def start_link(args) do
    GenServer.start_link(__MODULE__, args, [])
  end

  @impl GenServer
  def init([target_db, tasks_name]) do
    "Platform.App.Sync.Onliners.Logic start" |> Logger.info()

    {:ok, [keys: MapSet.new(), target_db: target_db, tasks_name: tasks_name],
     {:continue, :start_sync}}
  end

  @impl GenServer
  def handle_continue(:start_sync, state) do
    "Platform.App.Sync.Onliners.Logic starting sync" |> Logger.info()

    PubSub.subscribe(Chat.PubSub, @incoming_topic)
    PubSub.broadcast(Chat.PubSub, @outgoing_topic, "get_user_keys")

    Process.send_after(self(), :do_sync, 1000)

    {:noreply, state}
  end

  @impl GenServer
  def handle_info(:do_sync, state) do
    "Platform.App.Sync.Onliners.Logic syncing" |> Logger.info()

    backup_keys = KeyScope.get_keys(Chat.Db.db(), state[:keys])
    restoration_keys = KeyScope.get_keys(state[:target_db], state[:keys])

    opts =
      state
      |> Keyword.put(:backup_keys, backup_keys)
      |> Keyword.put(:restoration_keys, restoration_keys)

    {:ok, _pid} =
      OnlinersDynamicSupervisor
      |> DynamicSupervisor.start_child({Copier, opts})

    {:ok, _pid} =
      OnlinersDynamicSupervisor
      |> DynamicSupervisor.start_child(Stopper)

    {:noreply, state}
  end

  def handle_info({:user_keys, user_keys}, state) do
    keys =
      state
      |> Keyword.get(:keys)
      |> MapSet.union(user_keys)

    {:noreply, Keyword.put(state, :keys, keys)}
  end
end
