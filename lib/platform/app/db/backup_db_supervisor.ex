defmodule Platform.App.Db.BackupDbSupervisor do
  @moduledoc """
  Main DB device mount
  """
  use Supervisor

  require Logger

  alias Platform.Storage.Backup.Copier
  alias Platform.Storage.Backup.Starter
  alias Platform.Storage.Backup.Stopper

  def start_link(init_arg) do
    Supervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl true
  def init([_device]) do
    "Backup DB Supervisor start" |> Logger.info()
    mount_path = "/root/media"
    full_path = [mount_path, "bdb", Chat.Db.version_path()] |> Path.join()
    target_db = Chat.Db.BackupDb
    tasks = Platform.App.Db.BackupDbSupervisor.Tasks

    children = [
      {Task.Supervisor, name: tasks},
      {Task, fn -> File.mkdir_p!(full_path) end},
      {Chat.Db.MediaDbSupervisor, [target_db, full_path]},
      Starter,
      {Copier, target_db: target_db, tasks_name: tasks},
      Stopper
    ]

    Supervisor.init(children, strategy: :rest_for_one)
    |> tap(fn res ->
      "BackupDbSupervisor init result #{inspect(res)}" |> Logger.debug()
    end)
  end
end
