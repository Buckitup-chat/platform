defmodule Platform.App.Sync.Cargo.FinalScopeProvider do
  @moduledoc "Gets scope for cargo sync"

  use GracefulGenServer, name: __MODULE__

  alias Chat.Admin.CargoSettings
  alias Chat.AdminRoom
  alias Chat.Db.Scope.KeyScope
  alias Chat.Sync.CargoRoom

  @impl true
  def on_init(opts) do
    next = Keyword.fetch!(opts, :next)
    target_db = Keyword.fetch!(opts, :target)

    cargo_room_key = get_room_key(target_db)

    false = cargo_room_key |> is_nil()

    CargoRoom.sync(cargo_room_key)

    %CargoSettings{checkpoints: checkpoints} = AdminRoom.get_cargo_settings()
    backup_keys = KeyScope.get_keys(Chat.Db.db(), [cargo_room_key | checkpoints])
    restoration_keys = KeyScope.get_keys(target_db, [cargo_room_key | checkpoints])

    Process.send_after(self(), :next_stage, 10)

    %{
      next_spec: Keyword.fetch!(next, :run),
      next_under: Keyword.fetch!(next, :under),
      db_keys: {backup_keys, restoration_keys}
    }
  end

  @impl true
  def on_msg(:next_stage, %{next_spec: spec, next_under: supervisor} = state) do
    Platform.start_next_stage(supervisor, spec)

    {:noreply, state}
  end

  @impl true
  def handle_call(:db_keys, _from, state) do
    {:reply, state.db_keys, state}
  end

  @impl true
  def on_exit(_reason, _state) do
    CargoRoom.remove()
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
end
