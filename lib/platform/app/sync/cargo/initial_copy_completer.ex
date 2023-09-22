defmodule Platform.App.Sync.Cargo.InitialCopyCompleter do
  @moduledoc "Finishes initial room copying"

  use GracefulGenServer

  alias Chat.Sync.CargoRoom

  @impl true
  def on_init(opts) do
    opts
  end

  @impl true
  def on_exit(_reason, _state) do
    CargoRoom.mark_successful()
    CargoRoom.complete()
  end
end
