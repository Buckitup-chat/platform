defmodule Platform.PgDb do
  @moduledoc """
  PostgreSQL database handling for Nerves environment.
  Initializes, starts, and manages the PostgreSQL server.
  """

  require Logger

  # Default locations
  @pg_data_dir "/root/pg/data"
  @pg_run_dir "/root/pg/run"
  @postgres_user "postgres"

  # Startup configuration - use Application config with fallbacks
  @pg_port Application.compile_env(:chat, :pg_port, 5432)
  @pg_socket_dir Application.compile_env(:chat, :pg_socket_dir, "/root/pg/run")
  @pg_socket "#{@pg_socket_dir}/.s.PGSQL.#{@pg_port}"

  # Define minimal configuration settings for embedded environment
  @pg_minimal_settings [
    "-c", "shared_buffers=400kB",
    "-c", "max_connections=5",
    "-c", "dynamic_shared_memory_type=mmap",
    "-c", "max_prepared_transactions=0",
    "-c", "max_locks_per_transaction=32",
    "-c", "max_files_per_process=64",
    "-c", "work_mem=1MB",
    "-c", "unix_socket_directories=#{@pg_socket_dir}"
  ]

  @doc """
  Initialize the PostgreSQL database if not already initialized.
  Creates the data directory and performs `initdb`.
  """
  def initialize do
    # Ensure directories exist
    File.mkdir_p!(@pg_data_dir)
    File.mkdir_p!(@pg_run_dir)

    if initialized?() do
      Logger.info("PostgreSQL database already initialized")
      :ok
    else
      Logger.info("Initializing PostgreSQL database")
      do_initialize()
    end
  end

  @doc """
  Check if PostgreSQL is already initialized.
  """
  def initialized? do
    File.exists?("#{@pg_data_dir}/PG_VERSION")
  end

  @doc """
  Start the PostgreSQL server.
  """
  def start do
    case server_running?() do
      true ->
        Logger.info("PostgreSQL already running")
        :ok
      false ->
        Logger.info("Starting PostgreSQL server")
        do_start()
    end
  end

  @doc """
  Stop the PostgreSQL server.
  """
  def stop do
    case server_running?() do
      true ->
        Logger.info("Stopping PostgreSQL server")
        do_stop()
      false ->
        Logger.info("PostgreSQL server not running")
        :ok
    end
  end

  @doc """
  Run a SQL command against the PostgreSQL database.
  """
  def run_sql(sql, db_name \\ "postgres") do
    case server_running?() do
      true ->
        Logger.debug("Running SQL: #{sql} on database #{db_name}")
        # Add the socket directory to psql arguments
        args = [
          "-U", @postgres_user,
          "-d", db_name,
          "-c", sql,
          "-h", @pg_socket_dir  # Explicitly set the socket directory
        ]

        # We pass the PGHOST environment variable directly in the command

        {output, status} = System.cmd(
          "sudo",
          ["-u", @postgres_user, "env", "PGHOST=#{@pg_socket_dir}", "psql" | args],
          stderr_to_stdout: true
        )

        if status == 0 do
          {:ok, output}
        else
          {:error, output}
        end
      false ->
        Logger.error("Cannot run SQL: PostgreSQL server not running")
        {:error, "PostgreSQL server not running"}
    end
  end

  @doc """
  Create a new PostgreSQL database.
  """
  def create_database(db_name) do
    case server_running?() do
      true ->
        Logger.info("Creating database: #{db_name}")
        args = [
          "-U", @postgres_user,
          "-h", @pg_socket_dir, # Explicitly set the socket directory
          db_name
        ]
        {output, status} = System.cmd(
          "sudo",
          ["-u", @postgres_user, "env", "PGHOST=#{@pg_socket_dir}", "createdb" | args],
          stderr_to_stdout: true
        )

        if status == 0 do
          {:ok, db_name}
        else
          {:error, output}
        end
      false ->
        Logger.error("Cannot create database: PostgreSQL server not running")
        {:error, "PostgreSQL server not running"}
    end
  end

  @doc """
  Check if the PostgreSQL server is running.
  """
  def server_running? do
    socket_exists = File.exists?(@pg_socket)

    if socket_exists do
      # Double check with a simple SQL query
      case System.cmd("sudo", ["-u", @postgres_user, "env", "PGHOST=#{@pg_socket_dir}", "psql", "-U", @postgres_user, "-h", @pg_socket_dir, "-c", "SELECT 1"], stderr_to_stdout: true) do
        {_, 0} -> true
        _ -> false
      end
    else
      false
    end
  end

  @doc """
  Get the child specification for adding PostgreSQL to a supervision tree.
  """
  def child_spec do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, []},
      type: :worker,
      restart: :permanent,
      shutdown: 10_000
    }
  end

  @doc """
  Start function for the supervision tree.
  """
  def start_link do
    Task.start_link(fn ->
      initialize()
      start()
    end)
  end

  # Private functions

  defp do_initialize do
    # Get postgres user ID
    {postgres_uid_str, _} = System.cmd("id", ["-u", @postgres_user], stderr_to_stdout: true)
    {postgres_gid_str, _} = System.cmd("id", ["-g", @postgres_user], stderr_to_stdout: true)
    postgres_uid = String.trim(postgres_uid_str) |> String.to_integer()
    postgres_gid = String.trim(postgres_gid_str) |> String.to_integer()

    # Set permissions
    :file.change_owner(String.to_charlist(@pg_data_dir), postgres_uid, postgres_gid)
    File.chmod!(@pg_data_dir, 0o700)
    :file.change_owner(String.to_charlist(@pg_run_dir), postgres_uid, postgres_gid)
    File.chmod!(@pg_run_dir, 0o700)
    # Ensure parent directory is accessible
    :file.change_mode(String.to_charlist("/root/pg"), 0o711)

    # Run initdb
    args = ["--auth-host=trust", "--auth-local=trust", "-D", @pg_data_dir] ++ @pg_minimal_settings
    {output, status} = System.cmd("sudo", ["-u", @postgres_user, "/usr/bin/initdb" | args], stderr_to_stdout: true)

    if status == 0 do
      Logger.info("PostgreSQL database initialized successfully")
      :ok
    else
      Logger.error("PostgreSQL database initialization failed: #{output}")
      {:error, output}
    end
  end

  defp do_start do
    # Ensure the directory for socket exists
    File.mkdir_p!(@pg_socket_dir)
    {postgres_uid_str, _} = System.cmd("id", ["-u", @postgres_user], stderr_to_stdout: true)
    {postgres_gid_str, _} = System.cmd("id", ["-g", @postgres_user], stderr_to_stdout: true)
    postgres_uid = String.trim(postgres_uid_str) |> String.to_integer()
    postgres_gid = String.trim(postgres_gid_str) |> String.to_integer()
    :file.change_owner(String.to_charlist(@pg_socket_dir), postgres_uid, postgres_gid)
    File.chmod!(@pg_socket_dir, 0o700)

    # Start PostgreSQL
    args = [
      "-D", @pg_data_dir, 
      "-l", "/dev/null", 
      "-o", "#{Enum.join(@pg_minimal_settings, " ")} -c port=#{@pg_port} -c unix_socket_directories='#{@pg_socket_dir}' -c log_destination=stderr",
      "start"
    ]

    {output, status} = System.cmd(
      "sudo",
      ["-u", @postgres_user, "/usr/bin/pg_ctl" | args],
      stderr_to_stdout: true
    )

    # Give it a moment to start up
    Process.sleep(1000)

    if status == 0 and server_running?() do
      Logger.info("PostgreSQL server started successfully")
      :ok
    else
      Logger.error("PostgreSQL server failed to start: #{output}")
      {:error, output}
    end
  end

  defp do_stop do
    args = ["-D", @pg_data_dir, "stop", "-m", "fast"]

    {output, status} = System.cmd(
      "sudo",
      ["-u", @postgres_user, "/usr/bin/pg_ctl" | args],
      stderr_to_stdout: true
    )

    if status == 0 do
      Logger.info("PostgreSQL server stopped successfully")
      :ok
    else
      Logger.error("PostgreSQL server failed to stop: #{output}")
      {:error, output}
    end
  end
end
