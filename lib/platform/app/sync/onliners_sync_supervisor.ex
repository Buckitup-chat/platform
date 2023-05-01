defmodule Platform.App.Sync.OnlinersSyncSupervisor do
  @moduledoc """
  Starts supervision tree for online sync.
  """
  use Supervisor

  require Logger

  alias Chat.Db.MediaDbSupervisor
  alias Platform.App.Sync.Onliners.{Logic, OnlinersDynamicSupervisor}
  alias Platform.App.Sync.OnlinersSyncSupervisor.Tasks
  alias Platform.Storage.Backup.Starter
  alias Platform.Storage.Bouncer

  @mount_path Application.compile_env(:platform, :mount_path_media)

  def start_link(init_arg) do
    Supervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl true
  def init([_device]) do
    "OnlinersSyncSupervisor start" |> Logger.info()

    type = "onliners_db"
    full_path = [@mount_path, type, Chat.Db.version_path()] |> Path.join()
    tasks = Tasks
    target_db = Chat.Db.OnlinersDb

    children = [
      {Task.Supervisor, name: tasks},
      {Task, fn -> File.mkdir_p!(full_path) end},
      {MediaDbSupervisor, [target_db, full_path]},
      {Bouncer, db: target_db, type: type},
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
