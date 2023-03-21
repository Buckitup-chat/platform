defmodule Platform.App.Sync.CargoSyncSupervisor do
  use Supervisor

  require Logger

  alias Chat.Db.MediaDbSupervisor
  alias Platform.App.Sync.Cargo.{CargoDynamicSupervisor, Logic}
  alias Platform.App.Sync.CargoSyncSupervisor.Tasks
  alias Platform.Storage.Backup.Starter

  def start_link(init_arg) do
    Supervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl Supervisor
  def init([_device]) do
    "CargoSyncSupervisor start" |> Logger.info()

    env = Application.get_env(:platform, :env)
    mount_path = if(env == :test, do: "priv/test_media", else: "/root/media")
    full_path = [mount_path, "cargo_db", Chat.Db.version_path()] |> Path.join()
    target_db = Chat.Db.CargoDb
    tasks = Tasks

    children = [
      {Task.Supervisor, name: tasks},
      {Task, fn -> File.mkdir_p!(full_path) end},
      {MediaDbSupervisor, [target_db, full_path]},
      Starter,
      {DynamicSupervisor, name: CargoDynamicSupervisor, strategy: :one_for_one},
      {Logic, [target_db, tasks]}
    ]

    Supervisor.init(children, strategy: :rest_for_one)
    |> tap(fn res ->
      "CargoSyncSupervisor init result #{inspect(res)}" |> Logger.debug()
    end)
  end
end
