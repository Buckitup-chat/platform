defmodule Platform.Internal.PgDb do
  @moduledoc """
  Supervisor for PostgreSQL database processes.
  Handles initialization, startup, and monitoring of PostgreSQL server using staged approach.
  """
  use Supervisor

  import Platform

  require Logger

  @db_name Application.compile_env(:chat, Chat.Repo, database: "chat")[:database]
  @pg_port Application.compile_env(:chat, :pg_port, 5432)
  @pg_dir "/root/pg"

  if :host == Application.compile_env(:platform, :target) do
    @pg_daemon Platform.Emulator.EmptyBypass
    @pg_db_creator Platform.Emulator.EmptyBypass
    @pg_initializer Platform.Emulator.EmptyBypass
  else
    @pg_daemon Platform.Storage.Pg.Daemon
    @pg_db_creator Platform.Storage.Pg.DbCreator
    @pg_initializer Platform.Storage.Pg.Initializer
  end

  def start_link(args) do
    Supervisor.start_link(__MODULE__, args, name: __MODULE__)
  end

  @impl true
  def init(_args) do
    Logger.info("Starting PostgreSQL supervisor")

    supervision_tree()
    |> Supervisor.init(strategy: :rest_for_one, max_restarts: 1, max_seconds: 5)
  end

  defp supervision_tree do
    task_supervisor = Platform.Internal.PgDb.TaskSupervisor

    [
      use_task(task_supervisor),
      {:step, Platform.Internal.PgDb.InitPg,
       {@pg_initializer, pg_dir: @pg_dir, pg_port: @pg_port, task_in: task_supervisor}
       |> exit_takes(30_000)},
      {:stage, Platform.Internal.PgDb.PgServer,
       {@pg_daemon,
        pg_dir: @pg_dir, pg_port: @pg_port, name: :postgres_daemon, task_in: task_supervisor}
       |> exit_takes(180_000)},
      {Task, fn -> Process.sleep(5_000) end},
      {:step, Platform.Internal.PgDb.DbCreated,
       {@pg_db_creator, db_name: @db_name, pg_port: @pg_port, task_in: task_supervisor}
       |> exit_takes(15_000)}
    ]
    |> prepare_stages(Platform.Internal.PgDb.Stages)
  end
end
