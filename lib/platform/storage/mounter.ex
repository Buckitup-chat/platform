defmodule Platform.Storage.Mounter do
  @moduledoc """
  Mounts on start, unmount on terminate
  """
  use GracefulGenServer, timeout: :timer.minutes(1)

  require Logger

  alias Platform.Storage.Device
  alias Platform.Tools.Mount

  @impl true
  def on_init(opts) do
    next = opts |> Keyword.fetch!(:next)

    %{
      device: opts |> Keyword.fetch!(:device),
      path: opts |> Keyword.fetch!(:at),
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
          path: path,
          task_supervisor: task_supervisor,
          next_specs: next_specs,
          next_supervisor: next_supervisor
        } = state
      ) do
    Task.Supervisor.async_nolink(task_supervisor, fn ->
      device
      |> Device.mount_on(path)
    end)
    |> Task.await()

    Platform.start_next_stage(next_supervisor, next_specs)
    {:noreply, state}
  end

  @impl true
  def on_exit(reason, %{path: path, task_supervisor: task_supervisor}) do
    "mount cleanup #{path} #{inspect(reason)}" |> Logger.warn()

    Task.Supervisor.async_nolink(task_supervisor, fn ->
      Mount.unmount(path)
    end)
    |> Task.await()
  end
end
