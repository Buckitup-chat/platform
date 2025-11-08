defmodule Platform.Internal.PgDb do
  @moduledoc """
  Supervisor for PostgreSQL database processes.
  Handles initialization, startup, and monitoring of PostgreSQL server.
  """
  use Supervisor

  require Logger

  @db_name Application.compile_env(:chat, Chat.Repo, database: "chat")[:database]
  @pg_port Application.compile_env(:chat, :pg_port, 5432)
  @pg_dir "/root/pg"

  def start_link(args) do
    Supervisor.start_link(__MODULE__, args, name: __MODULE__)
  end

  @impl true
  def init(_args) do
    Logger.info("Starting PostgreSQL supervisor")
    Platform.Tools.Postgres.initialize(pg_dir: @pg_dir)
    Logger.info("PostgreSQL initialized successfully")

    [
      postgres_daemon_spec(),
      {Task, fn -> setup_chat_database() end} |> Supervisor.child_spec(id: make_ref()),
      Chat.Repo,
      {Task, fn -> Chat.RepoStarter.run_migrations() end} |> Supervisor.child_spec(id: make_ref())
    ]
    |> Supervisor.init(strategy: :rest_for_one, max_restarts: 1, max_seconds: 5)
  end

  defp postgres_daemon_spec do
    Platform.Tools.Postgres.daemon_spec(
      pg_dir: @pg_dir,
      pg_port: @pg_port,
      name: :postgres_daemon
    )
  end

  defp setup_chat_database do
    if wait_for_db_ready() == :ok,
      do: Platform.Tools.Postgres.create_database(@db_name, pg_port: @pg_port)
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
