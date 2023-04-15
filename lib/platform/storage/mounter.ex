defmodule Platform.Storage.Mounter do
  @moduledoc """
  Mounts on start, unmount on terminate
  """
  use GenServer

  require Logger

  alias Platform.Storage.Device
  alias Platform.Tools.Mount

  alias GracefulGenServer.Functions, as: Graceful

  def start_link(args) do
    GenServer.start_link(__MODULE__, args, timeout: :timer.minutes(1))
  end

  @impl true
  def init(args), do: Graceful.init(args, do: &on_start/1, as: __MODULE__)

  @impl true
  def handle_info(msg, state),
    do:
      Graceful.handle_info(msg, state,
        on_exit: &cleanup/2,
        on_msg: &handle_msg/2,
        as: __MODULE__
      )

  def handle_info({:EXIT, from, reason}, state) do
    Logger.info("exiting #{__MODULE__} #{inspect(self())} from #{inspect(from)}")
    cleanup(reason, state)
    {:stop, reason, state}
  end

  def handle_msg(some, state) do
    Logger.info("info msg #{inspect(some)}")

    state
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
