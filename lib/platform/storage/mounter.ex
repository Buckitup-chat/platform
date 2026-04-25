defmodule Platform.Storage.Mounter do
  @moduledoc """
  Mounts on start, unmount on terminate
  """
  use GracefulGenServer, timeout: :timer.minutes(1)
  use Toolbox.OriginLog

  alias Platform.Storage.Device
  alias Platform.Tools.Mount

  @impl true
  def on_init(opts) do
    next = opts |> Keyword.fetch!(:next)

    %{
      device: opts |> Keyword.fetch!(:device),
      path: opts |> Keyword.fetch!(:at),
      mount_options: opts |> Keyword.get(:mount_options, []),
      task_supervisor: opts |> Keyword.fetch!(:task_in),
      next_specs: next |> Keyword.fetch!(:run),
      next_supervisor: next |> Keyword.fetch!(:under),
      task_ref: nil
    }
    |> tap(fn _ -> send(self(), :start) end)
  end

  @impl true
  def on_msg(
        :start,
        %{
          device: device,
          path: path,
          mount_options: mount_options,
          task_supervisor: task_supervisor
        } = state
      ) do
    %{ref: ref} =
      Task.Supervisor.async_nolink(task_supervisor, fn ->
        Device.mount_on(device, path, mount_options)
      end)

    {:noreply, %{state | task_ref: ref}}
  end

  def on_msg({ref, _}, %{task_ref: ref} = state) do
    Process.demonitor(ref, [:flush])
    send(self(), :mounted)
    {:noreply, state}
  end

  def on_msg({:DOWN, ref, :process, _pid, reason}, %{task_ref: ref, device: device} = state) do
    log("mount failed for #{device}: #{inspect(reason)}", :error)
    {:stop, {:mount_failed, reason}, state}
  end

  def on_msg(:mounted, %{next_specs: next_specs, next_supervisor: next_supervisor} = state) do
    Platform.start_next_stage(next_supervisor, next_specs)
    {:noreply, state}
  end

  @impl true
  def on_exit(reason, %{path: path, task_supervisor: task_supervisor}) do
    log("mount cleanup #{path} #{inspect(reason)}", :warning)

    Task.Supervisor.start_child(task_supervisor, fn ->
      Process.sleep(2000)
      Mount.unmount(path)
    end)
  end
end
