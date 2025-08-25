defmodule Platform.Internal.PgDb do
  @moduledoc """
  Supervisor for PostgreSQL database processes.
  Handles initialization, startup, and monitoring of PostgreSQL server.
  """
  use Supervisor

  require Logger

  @db_name Application.compile_env(:chat, Chat.Repo, database: "chat")[:database]
  @pg_data_dir "/root/pg/data"

  def start_link(args) do
    Supervisor.start_link(__MODULE__, args, name: __MODULE__)
  end

  @impl true
  def init(_args) do
    Logger.info("Starting PostgreSQL supervisor")
    Platform.PgDb.initialize()
    Logger.info("PostgreSQL initialized successfully")

    [
      postgres_daemon_spec(),
      {Task, fn -> setup_chat_database() end}
    ]
    |> Supervisor.init(strategy: :rest_for_one, max_restarts: 1, max_seconds: 5)
  end

  defp postgres_daemon_spec do
    {postgres_uid_str, _} = MuonTrap.cmd("id", ["-u", "postgres"], stderr_to_stdout: true)
    postgres_uid = String.trim(postgres_uid_str) |> String.to_integer()

    pg_port = Application.get_env(:chat, :pg_port, 5432)
    pg_minimal_settings = Platform.PgDb.minimal_settings()

    {MuonTrap.Daemon,
     [
       "/usr/bin/postgres",
       ["-D", @pg_data_dir] ++
         pg_minimal_settings ++
         ["-c", "port=#{pg_port}", "-c", "log_destination=stderr"],
       [
         stderr_to_stdout: true,
         log_output: :debug,
         uid: postgres_uid,
         name: :postgres_daemon
       ]
     ]}
  end

  defp setup_chat_database do
    if wait_for_db_ready() == :ok,
      do: Platform.PgDb.ensure_db_exists(@db_name)
  end

  defp wait_for_db_ready do
    1..10
    |> Enum.reduce_while({:error, :timeout}, fn _i, acc ->
      if Platform.PgDb.server_running?() do
        {:halt, :ok}
      else
        Process.sleep(2000)
        {:cont, acc}
      end
    end)
  end
end
