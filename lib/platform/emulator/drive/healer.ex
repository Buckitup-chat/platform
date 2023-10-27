defmodule Platform.Emulator.Drive.Healer do
  @moduledoc """
    Heals device, checking all known FSs
  """
  use GracefulGenServer, timeout: :timer.minutes(3)

  @impl true
  def on_init(opts) do
    next = opts |> Keyword.fetch!(:next)

    %{
      device: opts |> Keyword.fetch!(:device),
      task_supervisor: opts |> Keyword.fetch!(:task_in),
      next_specs: next |> Keyword.fetch!(:run),
      next_supervisor: next |> Keyword.fetch!(:under)
    }
    |> tap(fn _ -> send(self(), :start) end)
  end

  @impl true
  def on_msg(
        :start,
        %{
          device: _device,
          task_supervisor: _task_supervisor,
          next_specs: next_specs,
          next_supervisor: next_supervisor
        } = state
      ) do
    Process.sleep(300)

    Platform.start_next_stage(next_supervisor, next_specs)
    {:noreply, state}
  end

  @impl true
  def on_exit(_reason, _state), do: :nothing
end
