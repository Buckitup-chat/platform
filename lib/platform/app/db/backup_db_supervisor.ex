defmodule Platform.App.Db.BackupDbSupervisor do
  @moduledoc """
  Main DB device mount
  """
  use Supervisor

  require Logger

  alias Chat.Admin.BackupSettings
  alias Chat.AdminRoom
  alias Platform.Storage.Backup.Copier

  @mount_path Application.compile_env(:platform, :mount_path_media)

  def start_link(init_arg) do
    Supervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl true
  def init([_device]) do
    "Backup DB Supervisor start" |> Logger.info()

    continuous? =
      case AdminRoom.get_backup_settings() do
        %BackupSettings{type: :continuous} ->
          true

        _ ->
          false
      end

    full_path = [@mount_path, "backup_db", Chat.Db.version_path()] |> Path.join()
    tasks = Platform.App.Db.BackupDbSupervisor.Tasks

    children = [
      {Task.Supervisor, name: tasks},
      {Task, fn -> File.mkdir_p!(full_path) end},
      {Chat.Db.MediaDbSupervisor, [Chat.Db.BackupDb, full_path]},
      {Copier, continuous?: continuous?, tasks_name: tasks}
    ]

    Supervisor.init(children, strategy: :rest_for_one)
    |> tap(fn res ->
      "BackupDbSupervisor init result #{inspect(res)}" |> Logger.debug()
    end)
  end
end
