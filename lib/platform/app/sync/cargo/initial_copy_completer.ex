defmodule Platform.App.Sync.Cargo.InitialCopyCompleter do
  @moduledoc "Finishes initial room copying"

  use GracefulGenServer

  alias Phoenix.PubSub

  alias Chat.Sync.CargoRoom

  @cargo_topic "chat::cargo_room"

  @impl true
  def on_init(opts) do
    send(self(), :perform)

    opts
  end

  @impl true
  def on_msg(:perform, state) do
    :ok = PubSub.broadcast!(Chat.PubSub, @cargo_topic, {:room, :load_new_messages})
    {:noreply, state}
  end

  @impl true
  def on_exit(_reason, _state) do
    CargoRoom.mark_successful()
    CargoRoom.complete()
  end
end
