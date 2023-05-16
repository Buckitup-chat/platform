defmodule Platform.Storage.MountedHealer do
  @moduledoc """
    Heals mounted device, checking all known FSs
  """
  use GracefulGenServer, timeout: :timer.minutes(3)

  alias Platform.Storage.Device

  @impl true
  def on_init([device, path, task_supervisor]) do
    Task.Supervisor.async_nolink(task_supervisor, fn ->
      Device.unmount(device)
      Device.heal(device)
      Device.mount_on(device, path)
    end)
    |> Task.await()

    device
  end

  @impl true
  def on_exit(_reason, _device), do: :nothing
end
