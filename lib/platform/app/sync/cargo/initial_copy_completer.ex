defmodule Platform.App.Sync.Cargo.InitialCopyCompleter do
  @moduledoc "Finishes initial room copying"

  use GracefulGenServer

  alias Chat.Sync.CargoRoom

  @impl true
  def on_init(opts) do
    CargoRoom.mark_successful()
    CargoRoom.complete()

    next = Keyword.fetch!(opts, :next)
    next_under = Keyword.fetch!(next, :under)
    next_spec = Keyword.fetch!(next, :run)

    Process.send_after(self(), {:next_stage, next_under, next_spec}, 10)
  end

  @impl true
  def on_msg({:next_stage, supervisor, spec}, keys) do
    Platform.start_next_stage(supervisor, spec)

    {:noreply, keys}
  end

  @impl true
  def on_exit(_reason, _state) do
    CargoRoom.complete()
  end
end
