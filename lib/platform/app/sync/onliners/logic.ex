defmodule Platform.App.Sync.Onliners.Logic do
  @moduledoc """
  Gathers keys from the online users and starts the sync process.
  """

  use GenServer

  require Logger

  alias Chat.Db.Scope.KeyScope
  alias Phoenix.PubSub
  alias Platform.App.Sync.Onliners.OnlinersDynamicSupervisor
  alias Platform.Storage.{Copier, Stopper}

  @incoming_topic "chat_onliners->platform_onliners"
  @outgoing_topic "platform_onliners->chat_onliners"

  def start_link(args) do
    GenServer.start_link(__MODULE__, args, [])
  end

  @impl GenServer
  def init([target_db, tasks_name]) do
    "Platform.App.Sync.Onliners.Logic start" |> Logger.info()

    {:ok, [target_db: target_db, tasks_name: tasks_name], {:continue, :start_sync}}
  end

  @impl GenServer
  def handle_continue(:start_sync, opts) do
    "Platform.App.Sync.Onliners.Logic starting sync" |> Logger.info()

    PubSub.subscribe(Chat.PubSub, @incoming_topic)
    PubSub.broadcast(Chat.PubSub, @outgoing_topic, "get_online_users_keys")

    receive do
      {:user_keys, user_keys} ->
        do_sync(opts, user_keys)
    end

    {:noreply, opts}
  end

  defp do_sync(opts, keys) do
    "Platform.App.Sync.Onliners.Logic syncing" |> Logger.info()

    backup_keys = KeyScope.get_keys(Chat.Db.db(), keys)
    restoration_keys = KeyScope.get_keys(opts[:target_db], keys)

    opts =
      opts
      |> Keyword.put(:backup_keys, backup_keys)
      |> Keyword.put(:restoration_keys, restoration_keys)

    {:ok, _pid} =
      OnlinersDynamicSupervisor
      |> DynamicSupervisor.start_child({Copier, opts})

    Stopper.start_link(wait: 100)
  end
end
