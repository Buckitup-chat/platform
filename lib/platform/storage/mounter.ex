defmodule Platform.Storage.Mounter do
  @moduledoc """
  Mounts on start, unmount on terminate
  """
  use GracefulGenServer, timeout: :timer.minutes(1)

  require Logger

  alias Platform.Storage.Device
  alias Platform.Tools.Mount

  @impl true
  def on_init([device, path, task_supervisor]) do
    Task.Supervisor.async_nolink(task_supervisor, fn ->
      device
      |> Device.heal()
      |> Device.mount_on(path)
    end)
    |> Task.await()

    {path, task_supervisor}
  end

  @impl true
  def on_exit(reason, {path, task_supervisor}) do
    "mount cleanup #{path} #{inspect(reason)}" |> Logger.warn()

    Task.Supervisor.async_nolink(task_supervisor, fn ->
      Mount.unmount(path)
    end)
    |> Task.await()
  end
end
