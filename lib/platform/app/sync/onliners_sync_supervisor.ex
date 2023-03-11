defmodule Platform.App.Sync.OnlinersSyncSupervisor do
  @moduledoc """
  Starts supervision tree for online sync.
  """
  use Supervisor

  require Logger

  alias Chat.Db.BackupDbSupervisor
  alias Platform.App.Sync.Onliners.{Logic, OnlinersDynamicSupervisor}
  alias Platform.App.Sync.OnlinersSyncSupervisor.Tasks
  alias Platform.Storage.Backup.Starter

  def start_link(init_arg) do
    Supervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl true
  def init([_device]) do
    "OnlinersSyncSupervisor start" |> Logger.info()
    mount_path = "/root/media"
    full_path = [mount_path, "onliners_db", Chat.Db.version_path()] |> Path.join()
    target_db = Chat.Db.OnlinersDb
    tasks = Tasks

    children = [
      {Task.Supervisor, name: tasks},
      {Task, fn -> File.mkdir_p!(full_path) end},
      {BackupDbSupervisor, [target_db, full_path]},
      Starter,
      {DynamicSupervisor, name: OnlinersDynamicSupervisor, strategy: :one_for_one},
      {Logic, [target_db, tasks]}
    ]

    Supervisor.init(children, strategy: :rest_for_one)
    |> tap(fn res ->
      "OnlinersSyncSupervisor init result #{inspect(res)}" |> Logger.debug()
    end)
  end
end
