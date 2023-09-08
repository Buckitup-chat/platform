defmodule Platform.App.Sync.Cargo.ScopeProvider do
  @moduledoc "Gets scope for cargo sync"

  use GracefulGenServer, name: __MODULE__

  alias Chat.Admin.CargoSettings
  alias Chat.AdminRoom
  alias Chat.Db.Scope.KeyScope
  alias Chat.Sync.CargoRoom

  alias Platform.App.Media.Supervisor, as: MediaSupervisor
  alias Platform.Storage.DriveIndication

  @impl true
  def on_init(opts) do
    target_db = Keyword.fetch!(opts, :target)
    cargo_room_key = get_room_key(target_db)

    if cargo_room_key do
      Process.send_after(self(), {:start, target_db, cargo_room_key}, 10)
      opts
    else
      DriveIndication.drive_refused()
      MediaSupervisor.terminate_all_stages()
    end
  end

  @impl true
  def on_msg({:start, target_db, cargo_room_key}, state) do
    CargoRoom.sync(cargo_room_key)

    %CargoSettings{checkpoints: checkpoint_cards} = AdminRoom.get_cargo_settings()
    cargo_user_identity = AdminRoom.get_cargo_user()

    checkpoint_pub_keys =
      checkpoint_cards
      |> Enum.map(fn %Chat.Card{pub_key: key} -> key end)

    keys_to_invite =
      if cargo_user_identity do
        cargo_user_identity
        |> Chat.Identity.pub_key()
        |> then(&[&1 | checkpoint_pub_keys])
      else
        checkpoint_pub_keys
      end

    backup_keys = KeyScope.get_cargo_keys(Chat.Db.db(), cargo_room_key, keys_to_invite)
    restoration_keys = KeyScope.get_cargo_keys(target_db, cargo_room_key, keys_to_invite)
    next = Keyword.fetch!(state, :next)

    Process.send_after(self(), :next_stage, 10)

    {
      :noreply,
      %{
        next_spec: Keyword.fetch!(next, :run),
        next_under: Keyword.fetch!(next, :under),
        db_keys: {backup_keys, restoration_keys}
      }
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
