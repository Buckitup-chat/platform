defmodule Platform.App.Db.BackupDbSupervisor do
  @moduledoc """
  Main DB device mount
  """
  use Supervisor

  require Logger

  alias Platform.Storage.Backup.Copier

  def start_link(init_arg) do
    Supervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl true
  def init([_device]) do
    "Backup DB Supervisor start" |> Logger.info()

    env = Application.get_env(:platform, :env)
    mount_path = if(env == :test, do: "priv/test_media", else: "/root/media")
    full_path = [mount_path, "main_db", Chat.Db.version_path()] |> Path.join()
    tasks = Platform.App.Db.BackupDbSupervisor.Tasks

    children = [
      {Task.Supervisor, name: tasks},
      {Task, fn -> File.mkdir_p!(full_path) end},
      {Chat.Db.MediaDbSupervisor, [Chat.Db.BackupDb, full_path]},
      {Copier, tasks}
    ]

    Supervisor.init(children, strategy: :rest_for_one)
    |> tap(fn res ->
      "BackupDbSupervisor init result #{inspect(res)}" |> Logger.debug()
    end)
  end
end
