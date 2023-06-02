defmodule Platform.App.Db.MainDbSupervisor do
  @moduledoc """
  Main DB device mount
  """
  use Supervisor
  require Logger

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
    Supervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl true
  def init([device]) do
    "Main Db Supervisor start" |> Logger.debug()

    full_path = [@mount_path, "main_db", Chat.Db.version_path()] |> Path.join()
    task_supervisor = Platform.App.Db.MainDbSupervisor.Tasks
    next_supervisor = Platform.App.Db.MainDbSupervisor.Next

    [
      {Task.Supervisor, name: task_supervisor},
      dir_creator(full_path),
      healer_unless_test(device, task_supervisor),
      mounter_unless_test(device, task_supervisor),
      {Chat.Db.MainDbSupervisor, full_path},
      {Bouncer, db: Chat.Db.MainDb, type: "main_db"},
      Starter,
      {DynamicSupervisor, strategy: :one_for_one, name: next_supervisor},
      {Copier,
       run_in: task_supervisor,
       next_run_in: next_supervisor,
       next_run_spec: fn -> {Supervisor, [MainReplicator, Switcher], strategy: :rest_for_one} end}
    ]
    |> Enum.reject(&is_nil/1)
    |> Supervisor.init(strategy: :rest_for_one)
  end

  defp dir_creator(path), do: {Task, fn -> File.mkdir_p!(path) end}

  defp healer_unless_test(device, tasks) do
    if not_test_env?() do
      {Healer, [device, tasks]}
    end
  end

  defp mounter_unless_test(device, tasks) do
    if not_test_env?() do
      {Mounter, [device, @mount_path, tasks]}
    end
  end

  defp not_test_env?, do: Application.get_env(:platform, :env) != :test
end
