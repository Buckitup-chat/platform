defmodule Platform.App.Sync.UsbDriveDump.Completer do
  @moduledoc "Finishes files dump into room"

  use GracefulGenServer

  alias Chat.Sync.UsbDriveDumpRoom
  alias Platform.Storage.DriveIndication

  @impl true
  def on_init(_args) do
    UsbDriveDumpRoom.complete()
    DriveIndication.drive_complete()
  end

  @impl true
  def on_exit(_reason, _state) do
  end
end
