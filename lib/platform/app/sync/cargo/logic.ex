defmodule Platform.App.Sync.Cargo.Logic do
  @moduledoc """
  Starts the sync process for cargo room messages.
  """

  use GenServer

  require Logger

  alias Chat.Db.Scope.KeyScope
  alias Chat.Rooms
  alias Chat.Rooms.Room
  alias Platform.App.Sync.Cargo.CargoDynamicSupervisor
  alias Platform.Storage.{Copier, Stopper}

  def start_link(args) do
    GenServer.start_link(__MODULE__, args, [])
  end

  @impl GenServer
  def init([target_db, tasks]) do
    "Platform.App.Sync.Cargo.Logic syncing" |> Logger.info()

    target_db
    |> get_room_key()
    |> do_sync(target_db: target_db, tasks_name: tasks)

    {:ok, nil}
  end

  defp get_room_key(target_db) do
    get_room_key_from_target_db(target_db) || get_room_key_from_internal_db()
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

  defp get_room_key_from_internal_db do
    case Rooms.list(%{}) do
      {_my_rooms, [%Room{} = cargo_room]} -> cargo_room.pub_key
      _ -> nil
    end
  end

  defp do_sync(nil, _opts) do
    "Platform.App.Sync.Cargo.Logic cannot decide which room is for cargo" |> Logger.error()

    {:ok, _pid} =
      CargoDynamicSupervisor
      |> DynamicSupervisor.start_child(Stopper)
  end

  defp do_sync(cargo_room_key, opts) do
    backup_keys = KeyScope.get_keys(Chat.Db.db(), [cargo_room_key])
    restoration_keys = KeyScope.get_keys(opts[:target_db], [cargo_room_key])

    opts =
      opts
      |> Keyword.put(:backup_keys, backup_keys)
      |> Keyword.put(:restoration_keys, restoration_keys)

    {:ok, _pid} =
      CargoDynamicSupervisor
      |> DynamicSupervisor.start_child({Copier, opts})

    {:ok, _pid} =
      CargoDynamicSupervisor
      |> DynamicSupervisor.start_child(Stopper)

    "Platform.App.Sync.Cargo.Logic syncing finished" |> Logger.info()
  end
end
