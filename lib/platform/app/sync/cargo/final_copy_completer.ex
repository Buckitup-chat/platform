defmodule Platform.App.Sync.Cargo.FinalCopyCompleter do
  @moduledoc "Finishes repeated room copying"

  use GracefulGenServer

  alias Platform.App.Media.Supervisor, as: MediaSupervisor
  alias Platform.Storage.DriveIndication

  @impl true
  def on_init(_opts) do
    send(self(), :start)
  end

  def on_msg(:start, state) do
    Process.sleep(2000)

    DriveIndication.drive_complete()
    MediaSupervisor.terminate_all_stages()

    {:noreply, state}
  end

  @impl true
  def on_exit(_reason, _state) do
  end
end
