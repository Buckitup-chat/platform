defmodule Platform.Storage.DriveIndicationStarter do
  @moduledoc "Light red led on start"
  use GracefulGenServer

  alias Chat.Sync.CargoRoom
  alias Platform.Storage.DriveIndication

  @impl true
  def on_init(opts) do
    send(self(), :accept)

    :ok
  end

  @impl true
  def on_msg(:accept, state) do
    DriveIndication.drive_accepted()

    {:noreply, state}
  end

  @impl true
  def on_exit(_reason, _device) do
    CargoRoom.remove()
    DriveIndication.drive_reset()
  end
end
