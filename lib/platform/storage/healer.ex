defmodule Platform.Storage.Healer do
  @moduledoc """
    Heals device, checking all known FSs
  """
  use GracefulGenServer, timeout: :timer.minutes(3)

  alias Platform.Storage.Device

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
          device: device,
          task_supervisor: task_supervisor,
          next_specs: next_specs,
          next_supervisor: next_supervisor
        } = state
      ) do
    Task.Supervisor.async_nolink(task_supervisor, fn ->
      Device.heal(device)
    end)
    |> Task.await(:timer.minutes(2))

    Platform.start_next_stage(next_supervisor, next_specs)
    {:noreply, state}
  end

  @impl true
  def on_exit(_reason, _device), do: :nothing
end
