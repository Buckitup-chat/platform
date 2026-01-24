defmodule Platform.Emulator.EmptyBypass do
  @moduledoc """
  A generic bypass module that does nothing.
  Immediately proceeds to the next stage without performing any work.
  Used in emulated environment to skip steps and stages that aren't needed.
  """
  use GracefulGenServer, timeout: :timer.seconds(5)
  use Toolbox.OriginLog

  @impl true
  def on_init(opts) do
    next = opts |> Keyword.fetch!(:next)

    %{
      next_specs: next |> Keyword.fetch!(:run),
      next_supervisor: next |> Keyword.fetch!(:under)
    }
    |> tap(fn _ -> send(self(), :skip) end)
  end

  @impl true
  def on_msg(:skip, %{next_specs: next_specs, next_supervisor: next_supervisor} = state) do
    log("skipping to next stage", :debug)
    Platform.start_next_stage(next_supervisor, next_specs)
    {:noreply, state}
  end

  @impl true
  def on_exit(_reason, _state) do
    :ok
  end
end
