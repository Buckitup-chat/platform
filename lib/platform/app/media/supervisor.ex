defmodule Platform.App.Media.Supervisor do
  @moduledoc "Supervisor for Media drive"
  use Supervisor

  import Platform

  require Logger

  alias Platform.App.Media.{Decider, FunctionalityDynamicSupervisor, TaskSupervisor}
  alias Platform.Storage.DriveIndication
  alias Platform.Storage.Healer
  alias Platform.Storage.Mounter

  @mount_path Application.compile_env(:platform, :mount_path_media)
  @stages_namespace Platform.App.MediaStages

  def start_link(args) do
    Supervisor.start_link(__MODULE__, args, name: __MODULE__, max_restarts: 1, max_seconds: 15)
  end

  @impl Supervisor
  def init([device]) do
    "Platform.App.Media.Supervisor start" |> Logger.info()

    task_supervisor = TaskSupervisor
    next_supervisor = FunctionalityDynamicSupervisor

    [
      use_task(task_supervisor),
      DriveIndication |> exit_takes(1000),
      {Task, fn -> DriveIndication.drive_accepted() end},
      healer_unless_test(device, task_supervisor),
      mounter_unless_test(device, task_supervisor),
      use_next_stage(next_supervisor) |> exit_takes(90_000),
      {Decider, [device, [mounted: @mount_path, next: [under: next_supervisor]]]}
    ]
    |> prepare_stages(@stages_namespace)
    |> Supervisor.init(strategy: :rest_for_one, max_restarts: 1, max_seconds: 5)
    |> tap(fn res ->
      "Platform.App.Media.Supervisor init result #{inspect(res)}" |> Logger.debug()
    end)
  end

  def terminate_all_stages do
    namespace_path = Module.split(@stages_namespace)
    namespace_length = length(namespace_path)
    module = __MODULE__

    Task.Supervisor.start_child(Platform.TaskSupervisor, fn ->
      FunctionalityDynamicSupervisor
      |> DynamicSupervisor.which_children()
      |> Enum.reverse()
      |> Enum.each(fn{ _, pid, _, _} ->
        FunctionalityDynamicSupervisor
        |> DynamicSupervisor.terminate_child(pid)
      end)

      module
      |> Supervisor.which_children()
      |> Enum.each(fn {id, _, _, _} ->
        if Module.split(id) |> Enum.take(namespace_length) == namespace_path do
          Logger.debug("Media Supervisor terminating child #{inspect(id)}")
          :ok = Supervisor.terminate_child(__MODULE__, id)
        end
      end)
      |> tap(fn _ ->
        "Platform.App.Media.Supervisor terminates all stages" |> Logger.debug()
      end)
    end)
  end

  defp mounter_unless_test(device, task_supervisor) do
    if Application.get_env(:platform, :env) != :test do
      {:stage, Mounting,
       {Mounter, device: device, at: @mount_path, task_in: task_supervisor} |> exit_takes(15_000)}
    end
  end

  defp healer_unless_test(device, task_supervisor) do
    if Application.get_env(:platform, :env) != :test do
      {:stage, Healing, {Healer, device: device, task_in: task_supervisor}}
    end
  end
end
