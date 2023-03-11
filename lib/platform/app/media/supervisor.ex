defmodule Platform.App.Media.Supervisor do
  use Supervisor

  require Logger

  alias Platform.App.Media.{Decider, FunctionalityDynamicSupervisor, TaskSupervisor}
  alias Platform.Storage.Mounter

  def start_link(args) do
    Supervisor.start_link(__MODULE__, args, name: __MODULE__)
  end

  @impl Supervisor
  def init([device]) do
    "Platform.App.Media.Supervisor start" |> Logger.info()

    mount_path = "/root/media"
    task_supervisor = TaskSupervisor

    children = [
      {Task.Supervisor, name: TaskSupervisor},
      {Mounter, [device, mount_path, task_supervisor]},
      {DynamicSupervisor, name: FunctionalityDynamicSupervisor, strategy: :one_for_one},
      {Decider, [device, mount_path]}
    ]

    Supervisor.init(children, strategy: :rest_for_one)
    |> tap(fn res ->
      "Platform.App.Media.Supervisor init result #{inspect(res)}" |> Logger.debug()
    end)
  end
end
