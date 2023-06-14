defmodule Platform.App.Sync.Cargo.InviteAcceptor do
  @moduledoc "Gets the room private key"

  use GracefulGenServer, name: __MODULE__

  alias Chat.Actor
  alias Chat.AdminRoom
  alias Chat.Sync.CargoRoom
  alias Chat.Dialogs

  @impl true
  def on_init(opts) do
    with %{pub_key: room_key} <- CargoRoom.get(),
         cargo_user when not is_nil(cargo_user) <- AdminRoom.get_cargo_user(),
         invite when not is_nil(invite) <-
           Dialogs.room_invite_for_user_to_room(cargo_user, room_key),
         room_identity <- Dialogs.extract_invite_room_identity(invite) do
      next = Keyword.fetch!(opts, :next)
      next_under = Keyword.fetch!(next, :under)
      next_spec = Keyword.fetch!(next, :run)

      Process.send_after(self(), {:next_stage, next_under, next_spec}, 10)
      Actor.new(cargo_user, [room_identity], [])
    else
      _ -> stop()
    end
  end

  @impl true
  def on_msg({:next_stage, supervisor, spec}, keys) do
    Platform.start_next_stage(supervisor, spec)

    {:noreply, keys}
  end

  @impl true
  def handle_call(:keys, _from, keys) do
    {:reply, keys, keys}
  end

  @impl true
  def on_exit(_reason, _state) do
    CargoRoom.remove()
  end

  defp stop, do: true = false
end
