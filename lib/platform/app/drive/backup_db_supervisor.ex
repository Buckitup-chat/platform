defmodule Platform.App.Drive.BackupDbSupervisor do
  @moduledoc """
  Main DB device mount
  """
  use Supervisor

  import Platform

  require Logger

  alias Chat.Admin.BackupSettings
  alias Chat.AdminRoom
  alias Platform.Storage.Backup.Copier
  alias Platform.Storage.Bouncer

  def start_link(init_arg) do
    Supervisor.start_link(__MODULE__, init_arg,
      name: __MODULE__,
      max_restarts: 1,
      max_seconds: 15
    )
  end

  @impl true
  def init([device, path]) do
    "Backup DB Supervisor start" |> Logger.info()

    type = "backup_db"
    full_path = [path, type, Chat.Db.version_path()] |> Path.join()
    tasks = Platform.App.Drive.BackupDbSupervisor.Tasks
    db = Chat.Db.BackupDb
    continuous? = match?(%BackupSettings{type: :continuous}, AdminRoom.get_backup_settings())

    [
      {Task.Supervisor, name: tasks},
      {Task, fn -> File.mkdir_p!(full_path) end},
      {Chat.Db.MediaDbSupervisor, [db, full_path]} |> exit_takes(20_000),
      {Bouncer, db: db, type: type},
      {Copier, continuous?: continuous?, tasks_name: tasks, device: device} |> exit_takes(35_000)
    ]
    |> Supervisor.init(strategy: :rest_for_one, max_restarts: 1, max_seconds: 5)
    |> tap(fn res ->
      "BackupDbSupervisor init result #{inspect(res)}" |> Logger.debug()
    end)
  end
end
