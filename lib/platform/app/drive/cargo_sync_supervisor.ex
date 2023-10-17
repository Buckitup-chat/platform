defmodule Platform.App.Drive.CargoSyncSupervisor do
  @moduledoc "Cargo scenario"
  use Supervisor

  import Platform

  require Logger

  alias Chat.Db.MediaDbSupervisor

  alias Platform.App.Sync.Cargo.{
    SensorsDataCollector,
    FinalCopyCompleter,
    InitialCopyCompleter,
    InviteAcceptor,
    ScopeProvider
  }

  alias Platform.App.Drive.CargoSyncSupervisor.Tasks
  alias Platform.Storage.Backup.Starter
  alias Platform.Storage.Bouncer
  alias Platform.Storage.Copier

  def start_link(init_arg) do
    Supervisor.start_link(__MODULE__, init_arg,
      name: __MODULE__,
      max_restarts: 1,
      max_seconds: 15
    )
  end

  @impl Supervisor
  def init([device, path]) do
    "CargoSyncSupervisor start" |> Logger.info()

    type = "cargo_db"
    full_path = [path, type, Chat.Db.version_path()] |> Path.join()
    tasks = Tasks
    target_db = Chat.Db.CargoDb

    children = [
      use_task(tasks),
      {Task, fn -> File.mkdir_p!(full_path) end},
      {MediaDbSupervisor, [target_db, full_path]} |> exit_takes(20_000),
      {Bouncer, db: target_db, type: type} |> exit_takes(1000),
      {Starter, flag: :cargo} |> exit_takes(500),
      {:stage, Ready, {ScopeProvider, target: target_db} |> exit_takes(1000)},
      {:stage, Copying,
       {Copier, target: target_db, task_in: tasks, get_db_keys_from: ScopeProvider}
       |> exit_takes(35_000)},
      InitialCopyCompleter |> exit_takes(1000),
      {:stage, InviteAccept, {InviteAcceptor, device: device} |> exit_takes(1000)},
      {:stage, CollectSensorsData,
       {SensorsDataCollector, get_keys_from: InviteAcceptor}
       |> exit_takes(1000)},
      {:stage, FinalCopying,
       {Copier, target: target_db, task_in: tasks, get_db_keys_from: SensorsDataCollector}
       |> exit_takes(35_000)},
      {FinalCopyCompleter, device: device} |> exit_takes(500)
    ]

    children
    |> prepare_stages(Platform.App.Drive.CargoScenarioStages)
    |> Supervisor.init(strategy: :rest_for_one, max_restarts: 1, max_seconds: 5)
  end
end
