defmodule Platform.Internal.PgDb do
  @moduledoc """
  Supervisor for PostgreSQL database processes.
  Handles initialization, startup, and monitoring of PostgreSQL server.
  """
  use Supervisor
  use OriginLog

  @db_name Application.compile_env(:chat, Chat.Repo, database: "chat")[:database]
  @pg_port Application.compile_env(:chat, :pg_port, 5432)
  @pg_dir "/root/pg"

  def start_link(args) do
    Supervisor.start_link(__MODULE__, args, name: __MODULE__)
  end

  @impl true
  def init(_args) do
    log("Starting PostgreSQL supervisor", :info)
    Platform.Tools.Postgres.initialize(pg_dir: @pg_dir)
    log("PostgreSQL initialized successfully", :info)

    [
      postgres_daemon_spec(),
      # Ensure database exists for Chat.Repo
      {Task, fn -> setup_chat_database(Chat.Repo) end} |> Supervisor.child_spec(id: make_ref()),
      Chat.Repo,
      # Run migrations for Chat.Repo
      {Task, fn -> Chat.RepoStarter.run_migrations(Chat.Repo) end}
      |> Supervisor.child_spec(id: make_ref()),

      # Ensure database exists for Chat.InternalRepo (may share DB, but safe to ensure)
      {Task, fn -> setup_chat_database(Chat.InternalRepo) end}
      |> Supervisor.child_spec(id: make_ref()),

      # Start Chat.InternalRepo for internal PG sync
      Chat.InternalRepo,

      # Run migrations for Chat.InternalRepo
      {Task, fn -> Chat.RepoStarter.run_migrations(Chat.InternalRepo) end}
      |> Supervisor.child_spec(id: make_ref())
    ]
    |> Supervisor.init(strategy: :rest_for_one, max_restarts: 10, max_seconds: 30)
  end

  defp postgres_daemon_spec do
    Platform.Tools.Postgres.daemon_spec(
      pg_dir: @pg_dir,
      pg_port: @pg_port,
      name: :postgres_daemon
    )
  end

  defp setup_chat_database(repo) do
    db_name =
      repo.config()
      |> Keyword.get(:database, @db_name)

    if wait_for_db_ready() == :ok do
      _ = Platform.Tools.Postgres.ensure_db_exists(db_name, pg_port: @pg_port)
    end
  end

  defp wait_for_db_ready do
    1..30
    |> Enum.reduce_while({:error, :timeout}, fn _i, acc ->
      if Platform.Tools.Postgres.server_running?(pg_port: @pg_port) do
        {:halt, :ok}
      else
        Process.sleep(1000)
        {:cont, acc}
      end
    end)
  end
end
