defmodule Platform.Storage.DriveIndicationStarter do
  @moduledoc false
  use GracefulGenServer

  alias Chat.Sync.CargoRoom
  alias Platform.Storage.DriveIndication

  @impl true
  def on_init(opts) do
    next = opts |> Keyword.fetch!(:next)
    next_specs = next |> Keyword.fetch!(:run)
    next_supervisor = next |> Keyword.fetch!(:under)

    send(self(), :accept)
    Platform.start_next_stage(next_supervisor, next_specs)

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
