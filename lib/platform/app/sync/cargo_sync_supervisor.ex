defmodule Platform.App.Sync.CargoSyncSupervisor do
  use Supervisor

  import Platform

  require Logger

  alias Chat.Db.MediaDbSupervisor

  alias Platform.App.Sync.Cargo.{
    CameraSensorsDataCollector,
    InitialCopyCompleter,
    InviteAcceptor,
    FinalCopyCompleter,
    ScopeProvider,
    ScopeProviderDuplicate
  }

  alias Platform.App.Sync.CargoSyncSupervisor.Tasks
  alias Platform.Storage.Backup.Starter
  alias Platform.Storage.Bouncer

  @mount_path Application.compile_env(:platform, :mount_path_media)

  def start_link(init_arg) do
    Supervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl Supervisor
  def init([_device]) do
    "CargoSyncSupervisor start" |> Logger.info()

    type = "cargo_db"
    full_path = [@mount_path, type, Chat.Db.version_path()] |> Path.join()
    tasks = Tasks
    target_db = Chat.Db.CargoDb
    scope_ready_stage = Platform.App.Sync.CargoScopeReadyStage
    after_copying_stage = Platform.App.Sync.CargoAfterCopyingStage
    invite_accept_stage = Platform.App.Sync.CargoInviteAcceptStage
    read_cam_sensors_stage = Platform.App.Sync.CargoReadCameraSensorsStage
    repeated_copying_stage = Platform.App.Sync.CargoRepeatedCopyingStage
    after_repeated_copying_stage = Platform.App.Sync.CargoAfterRepeatedCopyingStage

    children = [
      use_task(tasks),
      {Task, fn -> File.mkdir_p!(full_path) end},
      {MediaDbSupervisor, [target_db, full_path]},
      {Bouncer, db: target_db, type: type},
      {Starter, flag: :cargo},
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
              run: [
                use_next_stage(invite_accept_stage),
                {InitialCopyCompleter,
                 next: [
                   under: invite_accept_stage,
                   run: [
                     use_next_stage(read_cam_sensors_stage),
                     {InviteAcceptor,
                      next: [
                        under: read_cam_sensors_stage,
                        run: [
                          use_next_stage(repeated_copying_stage),
                          {
                            CameraSensorsDataCollector,
                            get_keys_from: InviteAcceptor
                            # next: [
                            #  under: repeated_copying_stage,
                            #  run: [
                            #    use_next_stage(after_repeated_copying_stage),
                            #    {Copier,
                            #     target: target_db,
                            #     task_in: tasks,
                            #     get_db_keys_from: ScopeProviderDuplicate,
                            #     next: [
                            #       under: after_repeated_copying_stage,
                            #       run: [FinalCopyCompleter]
                            #     ]}
                            #  ]
                            # ]
                          }
                        ]
                      ]}
                   ]
                 ]}
              ]
            ]}
         ]
       ]}
    ]

    Supervisor.init(children, strategy: :rest_for_one)
    |> tap(fn res ->
      "CargoSyncSupervisor init result #{inspect(res)}" |> Logger.debug()
    end)
  end
end
