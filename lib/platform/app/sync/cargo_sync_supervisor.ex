defmodule Platform.App.Sync.CargoSyncSupervisor do
  use Supervisor

  import Platform

  require Logger

  alias Chat.Db.MediaDbSupervisor

  alias Platform.App.Sync.Cargo.{
    CameraSensorsDataCollector,
    FinalCopyCompleter,
    FinalScopeProvider,
    InitialCopyCompleter,
    InviteAcceptor,
    ScopeProvider
  }

  alias Platform.App.Sync.CargoSyncSupervisor.Tasks
  alias Platform.Storage.Backup.Starter
  alias Platform.Storage.Bouncer
  alias Platform.Storage.Copier

  @mount_path Application.compile_env(:platform, :mount_path_media)

  def start_link(init_arg) do
    Supervisor.start_link(__MODULE__, init_arg, name: __MODULE__, max_restarts: 1, max_seconds: 15)
  end

  @impl Supervisor
  def init([_device]) do
    "CargoSyncSupervisor start" |> Logger.info()

    type = "cargo_db"
    full_path = [@mount_path, type, Chat.Db.version_path()] |> Path.join()
    tasks = Tasks
    target_db = Chat.Db.CargoDb

    children = [
      use_task(tasks),
      {Task, fn -> File.mkdir_p!(full_path) end},
      {MediaDbSupervisor, [target_db, full_path]} |> exit_takes(20_000),
      {Bouncer, db: target_db, type: type},
      {Starter, flag: :cargo},
      {:stage, Ready, {ScopeProvider, target: target_db}},
      {:stage, Copying,
       {Copier, target: target_db, task_in: tasks, get_db_keys_from: ScopeProvider}},
      {:stage, AfterCopying, {InitialCopyCompleter, []}},
      {:stage, InviteAccept, {InviteAcceptor, []}},
      {:stage, CollectCameraSensorsData,
       {CameraSensorsDataCollector, get_keys_from: InviteAcceptor}},
      {:stage, PreFinal, {FinalScopeProvider, target: target_db}},
      {:stage, FinalCopying,
       {Copier, target: target_db, task_in: tasks, get_db_keys_from: FinalScopeProvider}},
      {:stage, AfterFinalCopying, {FinalCopyCompleter, []}}
    ]

    children
    |> prepare_stages(Platform.App.Sync.CargoScenarioStages)
    |> Supervisor.init(strategy: :rest_for_one, max_restarts: 1, max_seconds: 5)
    |> tap(fn res ->
      "CargoSyncSupervisor init result #{inspect(res)}" |> Logger.debug()
    end)
  end
end
