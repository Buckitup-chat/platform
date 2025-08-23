defmodule Platform.Internal.PgDb do
  @moduledoc """
  Supervisor for PostgreSQL database processes.
  Handles initialization, startup, and monitoring of PostgreSQL server.
  """
  use Supervisor

  require Logger

  import Platform, only: [use_task: 1, exit_takes: 2, prepare_stages: 2]

  @db_name Application.get_env(:chat, Chat.Repo, database: "chat")[:database]
  @pg_data_dir "/root/pg/data"

  def start_link(args) do
    Supervisor.start_link(__MODULE__, args, name: __MODULE__)
  end

  @impl true
  def init(_args) do
    Logger.info("Starting PostgreSQL database supervisor")
    Platform.PgDb.initialize()
    Logger.info("PostgreSQL database initialized successfully")

    [
      postgres_daemon_spec(),
      {Task, fn -> Platform.PgDb.create_database(@db_name) end}
      # use_task(:postgres_tasks),
      #
      # # Stage 1: Initialize PostgreSQL
      # {:stage, :pg_initializer, {Platform.Internal.PgInitializer, []} |> exit_takes(120_000)},
      #
      # # Stage 2: Start PostgreSQL daemon after initialization
      # {:stage, :pg_daemon, postgres_daemon_spec() |> exit_takes(30_000)},
      #
      # # Stage 3: Set up chat database
      # {:stage, :chat_db, {Task, fn -> setup_chat_database() end} |> exit_takes(15_000)}
    ]
    # |> prepare_stages(Platform.Internal.PgStages)
    |> Supervisor.init(strategy: :rest_for_one, max_restarts: 1, max_seconds: 5)
  end

  # Create a MuonTrap.Daemon spec for PostgreSQL
  defp postgres_daemon_spec do
    {postgres_uid_str, _} = MuonTrap.cmd("id", ["-u", "postgres"], stderr_to_stdout: true)
    postgres_uid = String.trim(postgres_uid_str) |> String.to_integer()

    pg_port = Application.get_env(:chat, :pg_port, 5432)
    pg_minimal_settings = Platform.PgDb.minimal_settings()

    {MuonTrap.Daemon,
     [
       "/usr/bin/pg_ctl",
       [
         "-D",
         @pg_data_dir,
         "-l",
         "/dev/null",
         "-o",
         "#{Enum.join(pg_minimal_settings, " ")} -c port=#{pg_port} -c listen_addresses='localhost' -c log_destination=stderr",
         "start"
       ],
       [
         stderr_to_stdout: true,
         log_output: :debug,
         uid: postgres_uid,
         name: :postgres_daemon
       ]
     ]}
  end

  # defp setup_chat_database(attempts \\ 0) do
  #   max_attempts = 3
  #
  #   Logger.info("Setting up database for Chat.Repo (attempt #{attempts + 1}/#{max_attempts})")
  #
  #   with true <- attempts < max_attempts || attempts_ended(max_attempts),
  #        true <- Platform.PgDb.server_running?(),
  #        {:ok, db_exists} <- check_database_exists(),
  #        {:ok, result} <- (not db_exists && create_database()) || {:ok, :exists} do
  #     {:ok, result}
  #   else
  #     false ->
  #       Logger.error("PostgreSQL server not running, retrying in 2 seconds")
  #       Process.sleep(2000)
  #       setup_chat_database(attempts + 1)
  #
  #     {:error, reason} ->
  #       Logger.error("Error in database setup: #{inspect(reason)}")
  #       Process.sleep(1000)
  #       setup_chat_database(attempts + 1)
  #   end
  # end
  #
  # defp attempts_ended(max_attempts) do
  #   Logger.error("Failed to set up Chat database after #{max_attempts} attempts")
  #   {:error, :max_attempts_exceeded}
  # end
  #
  # defp check_database_exists() do
  #   case Platform.PgDb.run_sql("SELECT 1 FROM pg_database WHERE datname = 'chat'") do
  #     {:ok, output} ->
  #       exists = not String.contains?(output, "0 rows")
  #       {:ok, exists}
  #
  #     error ->
  #       error
  #   end
  # end
  #
  # defp create_database() do
  #   # Need to create database
  #   Logger.info("Creating 'chat' database")
  #
  #   case Platform.PgDb.create_database("chat") do
  #     {:ok, _} ->
  #       Logger.info("'chat' database created successfully")
  #       {:ok, :created}
  #
  #     error ->
  #       error
  #   end
  # end
end
