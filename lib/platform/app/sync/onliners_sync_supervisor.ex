defmodule Platform.App.Sync.OnlinersSyncSupervisor do
  @moduledoc """
  Starts supervision tree for online sync.
  """
  use Supervisor

  import Platform

  require Logger

  alias Chat.Db.MediaDbSupervisor
  alias Platform.App.Sync.Onliners.ScopeProvider
  alias Platform.App.Sync.OnlinersSyncSupervisor.Tasks
  alias Platform.Storage.Backup.Starter
  alias Platform.Storage.Bouncer
  alias Platform.Storage.Copier
  alias Platform.Storage.Stopper

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
    scope_ready_stage = Platform.App.Sync.OnlinersScopeReadyStage
    after_copying_stage = Platform.App.Sync.OnlinersAfterCopyingStage

    [
      use_task(tasks),
      {Task, fn -> File.mkdir_p!(full_path) end},
      {MediaDbSupervisor, [target_db, full_path]},
      {Bouncer, db: target_db, type: type},
      Starter,
      use_next_stage(scope_ready_stage),
      {ScopeProvider,
       target: target_db,
       next: [
         under: scope_ready_stage,
         run: [
           use_next_stage(after_copying_stage),
           {Copier,
            target: target_db,
            task_in: tasks,
            get_db_keys_from: ScopeProvider,
            next: [
              under: after_copying_stage,
              run: [Stopper]
            ]}
         ]
       ]}
    ]
    |> Supervisor.init(strategy: :rest_for_one, max_restarts: 1, max_seconds: 5)
  end
end
