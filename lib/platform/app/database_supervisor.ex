defmodule Platform.App.DatabaseSupervisor do
  @moduledoc """
  Supervisor for PostgreSQL database processes using staged initialization.
  Mirrors the boot supervisor's approach for internal database setup.
  """
  use Supervisor
  use Toolbox.OriginLog

  import Platform

  alias Chat.Storage.Default
  alias Chat.Storage.Unit

  @db_name Application.compile_env(:chat, Chat.Repo, database: "chat")[:database]
  @pg_port Application.compile_env(:chat, :pg_port, 5432)
  @pg_dir "/root/pg"

  if :host == Application.compile_env(:platform, :target) do
    @pg_daemon Platform.Emulator.EmptyBypass
    @pg_db_creator Platform.Emulator.EmptyBypass
    @pg_initializer Platform.Emulator.EmptyBypass
    @pg_repo_starter Platform.Emulator.EmptyBypass
    @pg_migration_runner Platform.Emulator.EmptyBypass
  else
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

    # Staging order:
    # 1. Initialize PG -> 2. Start PG Daemon -> 3. Create Chat DB -> 4. Start Chat.Repo
    # 5. Run Chat migrations -> 6. Start ChunkPipeline -> 7. Electric via Default (internal)

    [
      use_task(task_supervisor),
      {:step, InitPg,
       {@pg_initializer, pg_dir: @pg_dir, pg_port: @pg_port, task_in: task_supervisor}
       |> exit_takes(30_000)},
      {:stage, PgServer,
       {@pg_daemon,
        pg_dir: @pg_dir, pg_port: @pg_port, name: :postgres_daemon, task_in: task_supervisor}
       |> exit_takes(180_000)},
      {:step, ChatDbCreated,
       {@pg_db_creator, db_name: @db_name, pg_port: @pg_port, task_in: task_supervisor}
       |> exit_takes(15_000)},
      {:stage, ChatRepoStarted,
       {@pg_repo_starter, name: Chat.Repo, port: @pg_port, task_in: task_supervisor}
       |> exit_takes(30_000)},
      {:step, ChatMigrationsRun,
       {@pg_migration_runner, repo_name: Chat.Repo, task_in: task_supervisor}
       |> exit_takes(60_000)},
      {Chat.Data.File.ChunkPipelineSupervisor, unit: Unit.internal()},
      {Task, &start_electric_on_internal/0}
    ]
    |> prepare_stages(Platform.App.DatabaseStages)
    |> Supervisor.init(strategy: :rest_for_one, max_restarts: 10, max_seconds: 30)
  end

  # Internal PG is (re)up. Electric follows Default, so a restart while main is
  # Default leaves it on main.
  defp start_electric_on_internal do
    case Default.unit() do
      %Unit{id: :internal} -> Default.switch_to(Unit.internal())
      %Unit{id: id} -> log("internal PG up, Default stays #{inspect(id)}", :info)
    end
  end
end
