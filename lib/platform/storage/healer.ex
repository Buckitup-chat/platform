defmodule Platform.Storage.Healer do
  @moduledoc """
    Heals device, checking all known FSs
  """
  use GracefulGenServer, timeout: :timer.minutes(3)

  alias Platform.Storage.Device

  @impl true
  def on_init([device, task_supervisor]) do
    Task.Supervisor.async_nolink(task_supervisor, fn ->
      Device.heal(device)
    end)
    |> Task.await()

    device
  end

  @impl true
  def on_exit(_reason, _device), do: :nothing
end
