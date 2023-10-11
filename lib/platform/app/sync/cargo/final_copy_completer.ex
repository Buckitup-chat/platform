defmodule Platform.App.Sync.Cargo.FinalCopyCompleter do
  @moduledoc "Finishes repeated room copying"

  use GracefulGenServer

  alias Platform.Storage.DriveIndication
  alias Platform.UsbDrives.Drive

  @impl true
  def on_init(opts) do
    send(self(), :start)
    opts
  end

  @impl true
  def on_msg(:start, opts) do
    Process.sleep(2000)

    DriveIndication.drive_complete()
    Drive.terminate(opts[:device])

    {:noreply, opts}
  end

  @impl true
  def on_exit(_reason, _state) do
  end
end
