defmodule Platform.Storage.Mounter do
  @moduledoc """
  Mounts on start, unmount on terminate
  """
  use GenServer

  require Logger

  alias Platform.Storage.Device
  alias Platform.Tools.Mount

  def start_link(args) do
    GenServer.start_link(__MODULE__, args, timeout: :timer.minutes(1))
  end

  @impl true
  def init(args) do
    Logger.info("starting #{__MODULE__} #{inspect(args)}")
    Process.flag(:trap_exit, true)
    state = on_start(args)
    inspect(state) |> Logger.debug()
    {:ok, state}
  end

  # handle the trapped exit call
  @impl true
  def handle_info({:EXIT, from, _}, state) when is_port(from), do: {:noreply, state}

  def handle_info({:EXIT, from, reason}, state) do
    Logger.info("exiting #{__MODULE__} #{inspect(self())} from #{inspect(from)}")
    cleanup(reason, state)
    {:stop, reason, state}
  end

  def handle_info(some, _, state) do
    Logger.info("info msg #{inspect(some)}")

    {:noreply, state}
  end

  # handle termination
  @impl true
  def terminate(reason, state) do
    Logger.info("terminating #{__MODULE__}")
    cleanup(reason, state)
    state
  end

  defp on_start([device, path, task_supervisor]) do
    Task.Supervisor.async_nolink(task_supervisor, fn ->
      device
      |> Device.heal()
      |> Device.mount_on(path)
    end)
    |> Task.await()

    {path, task_supervisor}
  end

  defp cleanup(reason, {path, task_supervisor}) do
    "mount cleanup #{path} #{inspect(reason)}" |> Logger.warn()

    Task.Supervisor.async_nolink(task_supervisor, fn ->
      Mount.unmount(path)
    end)
    |> Task.await()
  end
end
