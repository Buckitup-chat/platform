defmodule Platform.App.Sync.Cargo.InviteAcceptor do
  @moduledoc "Gets the room private key"

  use GracefulGenServer, name: __MODULE__

  alias Chat.Actor
  alias Chat.AdminRoom
  alias Chat.Dialogs
  alias Chat.Identity
  alias Chat.Sync.CargoRoom

  alias Platform.App.Media.Supervisor, as: MediaSupervisor
  alias Platform.Storage.DriveIndication

  @impl true
  def on_init(opts) do
    send(self(), :start)
    opts
  end

  @impl true
  def on_msg(:start, opts) do
    with %{pub_key: room_key} <- CargoRoom.get(),
         {:ok, cargo_user} <- get_cargo_user(),
         invite when not is_nil(invite) <-
           Dialogs.room_invite_for_user_to_room(cargo_user, room_key),
         room_identity <- Dialogs.extract_invite_room_identity(invite) do
      DriveIndication.drive_accepted()

      next = Keyword.fetch!(opts, :next)
      next_under = Keyword.fetch!(next, :under)
      next_spec = Keyword.fetch!(next, :run)

      send(self(), {:next_stage, next_under, next_spec})
      Actor.new(cargo_user, [room_identity], [])
    else
      {:error, :no_cargo_user} ->
        DriveIndication.drive_complete()
        MediaSupervisor.terminate_all_stages()

      _ ->
        DriveIndication.drive_refused()
        MediaSupervisor.terminate_all_stages()
    end
    |> then(&{:noreply, &1})
  end

  def on_msg({:next_stage, supervisor, spec}, state) do
    Platform.start_next_stage(supervisor, spec)

    {:noreply, state}
  end

  @impl true
  def handle_call(:keys, _from, state) do
    {:reply, state, state}
  end

  @impl true
  def on_exit(_reason, _state) do
  end

  defp get_cargo_user do
    case AdminRoom.get_cargo_user() do
      %Identity{} = cargo_user -> {:ok, cargo_user}
      _ -> {:error, :no_cargo_user}
    end
  end
end
