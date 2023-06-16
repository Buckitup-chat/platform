defmodule Platform.App.Sync.Cargo.RepeatedCopyCompleter do
  @moduledoc "Finishes repeated room copying"

  use GracefulGenServer

  alias Chat.Sync.CargoRoom

  @impl true
  def on_init(_opts) do
    CargoRoom.mark_successful()
    CargoRoom.complete()
  end

  @impl true
  def on_exit(_reason, _state) do
    CargoRoom.complete()
  end
end
