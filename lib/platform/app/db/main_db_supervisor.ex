defmodule Platform.App.Db.MainDbSupervisor do
  @moduledoc """
  Main DB device mount
  """
  use Supervisor
  require Logger

  import Platform

  alias Platform.Storage.{
    Bouncer,
    Healer,
    MainReplicator,
    Mounter
  }

  alias Platform.Storage.InternalToMain.{
    Copier,
    Starter,
    Switcher
  }

  @mount_path Application.compile_env(:platform, :mount_path_storage)

  def start_link(init_arg) do
    Supervisor.start_link(__MODULE__, init_arg, name: __MODULE__, max_restarts: 0, max_seconds: 15)
  end

  @impl true
  def init([device]) do
    "Main Db Supervisor start" |> Logger.debug()

    full_path = [@mount_path, "main_db", Chat.Db.version_path()] |> Path.join()
    task_supervisor = Platform.App.Db.MainDbSupervisor.Tasks

    [
      use_task(task_supervisor),
      dir_creator(full_path),
      healer_unless_test(device, task_supervisor),
      mounter_unless_test(device, task_supervisor),
      {Chat.Db.MainDbSupervisor, full_path},
      {Bouncer, db: Chat.Db.MainDb, type: "main_db"},
      Starter,
      {:stage, Copying, {Copier, task_in: task_supervisor}},
      MainReplicator,
      Switcher
    ]
    |> prepare_stages(Platform.App.MainStages)
    |> Supervisor.init(strategy: :rest_for_one, max_restarts: 1, max_seconds: 5)
  end

  defp dir_creator(path), do: {Task, fn -> File.mkdir_p!(path) end}

  defp healer_unless_test(device, tasks) do
    if not_test_env?() do
      {:stage, Healing, {Healer, device: device, task_in: tasks}}
    end
  end

  defp mounter_unless_test(device, tasks) do
    if not_test_env?() do
      {:stage, Mounting, {Mounter, device: device, at: @mount_path, task_in: tasks}}
    end
  end

  defp not_test_env?, do: Application.get_env(:platform, :env) != :test
end
