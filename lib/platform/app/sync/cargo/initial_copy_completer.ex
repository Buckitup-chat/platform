defmodule Platform.App.Sync.Cargo.InitialCopyCompleter do
  @moduledoc "Finishes initial room copying"

  use GracefulGenServer

  alias Chat.Sync.CargoRoom

  @impl true
  def on_init(_opts) do
    CargoRoom.mark_successful()
  end

  @impl true
  def on_exit(_reason, _state) do
    CargoRoom.complete()
  end
end
