defmodule Platform.App.Sync.Cargo.FinalCopyCompleter do
  @moduledoc "Finishes repeated room copying"

  use GracefulGenServer

  alias Platform.App.Media.Helpers
  alias Platform.Storage.DriveIndication

  @impl true
  def on_init(_opts) do
    DriveIndication.drive_complete()
    Helpers.terminate_stages()
  end

  @impl true
  def on_exit(_reason, _state) do
  end
end
