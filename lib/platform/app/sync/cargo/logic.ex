defmodule Platform.App.Sync.Cargo.Logic do
  @moduledoc """
  Starts the sync process for cargo room messages.
  """

  # TODO: ensure we do not use it, then delete

  use GracefulGenServer

  require Logger

  alias Chat.Admin.CargoSettings
  alias Chat.AdminRoom
  alias Chat.Db.Scope.KeyScope
  alias Chat.Sync.CargoRoom
  alias Phoenix.PubSub
  alias Platform.App.Sync.Cargo.CargoDynamicSupervisor
  alias Platform.Storage.{Copier, Stopper}

  @incoming_topic "chat_cargo->platform_cargo"

  @impl true
  def on_init(args) do
    sync(args)
    PubSub.subscribe(Chat.PubSub, @incoming_topic)

    args
  end

  @impl true
  def on_msg(:sync, args) do
    sync(args)
    {:noreply, args}
  end

  @impl true
  def on_exit(_reason, _state) do
    PubSub.unsubscribe(Chat.PubSub, @incoming_topic)
    CargoRoom.remove()
  end

  defp sync([target_db, tasks]) do
    "Platform.App.Sync.Cargo.Logic syncing" |> Logger.info()

    target_db
    |> get_room_key()
    |> do_sync(target_db: target_db, tasks_name: tasks)
  end

  defp get_room_key(target_db) do
    get_room_key_from_target_db(target_db) || CargoRoom.get_room_key()
  end

  defp get_room_key_from_target_db(target_db) do
    CubDB.with_snapshot(target_db, fn snap ->
      snap
      |> CubDB.Snapshot.select(min_key: {:rooms, 0}, max_key: {:"rooms\0", 0})
      |> Stream.take(1)
      |> Stream.map(fn {{:rooms, room_key}, _value} -> room_key end)
      |> Enum.to_list()
      |> List.first()
    end)
  end

  defp do_sync(nil, _opts) do
    "Platform.App.Sync.Cargo.Logic cannot decide which room is for cargo" |> Logger.error()

    CargoRoom.complete()

    Stopper.start_link(wait: 100)
  end

  defp do_sync(cargo_room_key, opts) do
    CargoRoom.sync(cargo_room_key)

    %CargoSettings{checkpoints: checkpoints} = AdminRoom.get_cargo_settings()
    backup_keys = KeyScope.get_keys(Chat.Db.db(), [cargo_room_key | checkpoints])
    restoration_keys = KeyScope.get_keys(opts[:target_db], [cargo_room_key | checkpoints])

    opts =
      opts
      |> Keyword.put(:backup_keys, backup_keys)
      |> Keyword.put(:restoration_keys, restoration_keys)

    {:ok, _pid} =
      CargoDynamicSupervisor
      |> DynamicSupervisor.start_child({Copier, opts})

    CargoRoom.mark_successful()
    CargoRoom.complete()

    "Platform.App.Sync.Cargo.Logic syncing finished" |> Logger.info()
  end
end
