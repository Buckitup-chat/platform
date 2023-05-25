defmodule Platform.App.Media.Supervisor do
  use Supervisor

  require Logger

  alias Platform.App.Media.{Decider, FunctionalityDynamicSupervisor, TaskSupervisor}
  alias Platform.Storage.Mounter

  @mount_path Application.compile_env(:platform, :mount_path_media)

  def start_link(args) do
    Supervisor.start_link(__MODULE__, args, name: __MODULE__)
  end

  @impl Supervisor
  def init([device]) do
    "Platform.App.Media.Supervisor start" |> Logger.info()

    task_supervisor = TaskSupervisor

    [
      {Task.Supervisor, name: task_supervisor},
      healer_unless_test(device, task_supervisor),
      mounter_unless_test(device, task_supervisor),
      {DynamicSupervisor, name: FunctionalityDynamicSupervisor, strategy: :one_for_one},
      {Decider, [device, @mount_path]}
    ]
    |> Supervisor.init(strategy: :rest_for_one)
    |> tap(fn res ->
      "Platform.App.Media.Supervisor init result #{inspect(res)}" |> Logger.debug()
    end)
  end

  defp mounter_unless_test(device, task_supervisor) do
    if Application.get_env(:platform, :env) != :test do
      {Mounter, [device, @mount_path, task_supervisor]}
    end
  end

  defp healer_unless_test(device, task_supervisor) do
    if Application.get_env(:platform, :env) != :test do
      {Platform.Storage.Healer, [device, task_supervisor]}
    end
  end
end
