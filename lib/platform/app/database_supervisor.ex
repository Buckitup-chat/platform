defmodule Platform.App.DatabaseSupervisor do
  @moduledoc """
  Supervisor for PostgreSQL database processes using staged initialization.
  Mirrors the boot supervisor's approach for internal database setup.
  """
  use Supervisor
  use Toolbox.OriginLog

  import Platform

  alias Chat.Storage.Unit

  @db_name Application.compile_env(:chat, Chat.Repo, database: "chat")[:database]

  if :host == Application.compile_env(:platform, :target) do
    @pq_reset Platform.Emulator.EmptyBypass
    @pg_daemon Platform.Emulator.EmptyBypass
    @pg_db_creator Platform.Emulator.EmptyBypass
    @pg_initializer Platform.Emulator.EmptyBypass
    @pg_repo_starter Platform.Emulator.EmptyBypass
    @pg_migration_runner Platform.Emulator.EmptyBypass
  else
    @pq_reset Platform.Storage.PqReset
    @pg_daemon Platform.Storage.Pg.Daemon
    @pg_db_creator Platform.Storage.Pg.DbCreator
    @pg_initializer Platform.Storage.Pg.Initializer
    @pg_repo_starter Platform.Storage.Repo.Starter
    @pg_migration_runner Platform.Storage.Repo.MigrationRunner
  end

  def start_link(args) do
    Supervisor.start_link(__MODULE__, args, name: __MODULE__, timeout: :timer.minutes(5))
  end

  @impl true
  def init(_args) do
    log("Starting PostgreSQL supervisor with staged initialization", :info)

    task_supervisor = __MODULE__.TaskSupervisor
    unit = Unit.internal()
    pg_dir = Unit.path(unit, :pg)
    pg_port = Unit.pg_port(unit)
    run_dir = Unit.pg_run(unit)

    # Staging order:
    # 0. PQ reset -> 1. Initialize PG -> 2. Start PG Daemon -> 3. Create Chat DB
    # 4. Start Chat.Repo -> 5. Run Chat migrations -> 6. Initialize PhoenixSync
    # 7. Start ChunkPipeline

    [
      use_task(task_supervisor),
      {:step, PqReset, {@pq_reset, unit: unit} |> exit_takes(15_000)},
      {:step, InitPg,
       {@pg_initializer,
        pg_dir: pg_dir, pg_port: pg_port, run_dir: run_dir, task_in: task_supervisor}
       |> exit_takes(30_000)},
      {:stage, PgServer,
       {@pg_daemon,
        pg_dir: pg_dir,
        pg_port: pg_port,
        run_dir: run_dir,
        name: :postgres_daemon,
        task_in: task_supervisor}
       |> exit_takes(180_000)},
      {:step, ChatDbCreated,
       {@pg_db_creator, db_name: @db_name, pg_port: pg_port, task_in: task_supervisor}
       |> exit_takes(15_000)},
      {:stage, ChatRepoStarted,
       {@pg_repo_starter, name: Unit.repo(unit), port: pg_port, task_in: task_supervisor}
       |> exit_takes(30_000)},
      {:step, ChatMigrationsRun,
       {@pg_migration_runner, repo_name: Unit.repo(unit), task_in: task_supervisor}
       |> exit_takes(60_000)},
      {:step, PhoenixSyncReady,
       {Platform.Storage.PhoenixSyncInit, task_in: task_supervisor}
       |> exit_takes(15_000)},
      {Chat.Data.File.ChunkPipelineSupervisor, unit: unit}
    ]
    |> prepare_stages(Platform.App.DatabaseStages)
    |> Supervisor.init(strategy: :rest_for_one, max_restarts: 10, max_seconds: 30)
  end
end
