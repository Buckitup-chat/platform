defmodule Platform.PgDb do
  @moduledoc """
  PostgreSQL database handling for Nerves environment.
  Initializes, starts, and manages the PostgreSQL server.
  """

  # Explicitly define MuonTrap dependency
  alias MuonTrap
  require Logger

  # Default locations
  @pg_data_dir "/root/pg/data"
  @pg_run_dir "/root/pg/run"
  @postgres_user "postgres"

  # Startup configuration - use Application config with fallbacks
  @pg_port Application.compile_env(:chat, :pg_port, 5432)
  # Use localhost for TCP connections
  @pg_host "localhost"

  # Define minimal configuration settings for embedded environment
  @pg_minimal_settings [
    "-c",
    "shared_buffers=400kB",
    "-c",
    "max_connections=15",
    "-c",
    "dynamic_shared_memory_type=mmap",
    "-c",
    "max_prepared_transactions=0",
    "-c",
    "max_locks_per_transaction=32",
    "-c",
    "max_files_per_process=64",
    "-c",
    "work_mem=1MB",
    "-c",
    "wal_level=logical",
    "-c",
    "listen_addresses=localhost",
    "-c",
    "unix_socket_directories=#{@pg_run_dir}"
  ]

  @doc """
  Returns the minimal PostgreSQL settings used for configuration.
  """
  def minimal_settings do
    @pg_minimal_settings
  end

  @doc """
  Initialize the PostgreSQL database if not already initialized.
  Creates the data directory and performs `initdb`.
  """
  def initialize do
    {postgres_uid_str, _} = MuonTrap.cmd("id", ["-u", @postgres_user], stderr_to_stdout: true)
    {postgres_gid_str, _} = MuonTrap.cmd("id", ["-g", @postgres_user], stderr_to_stdout: true)
    postgres_uid = String.trim(postgres_uid_str) |> String.to_integer()
    postgres_gid = String.trim(postgres_gid_str) |> String.to_integer()

    File.mkdir_p!(@pg_data_dir)
    File.mkdir_p!(@pg_run_dir)

    [@pg_data_dir, @pg_run_dir]
    |> ensure_dirs_permissions(postgres_uid, postgres_gid)

    File.chmod!("/root/pg", 0o755)

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

        {output, status} =
          run_pg("psql", ["-d", db_name, "-c", sql], as_postgres_user: true)

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

        # First check if database already exists
        {:ok, output} = run_sql("SELECT datname FROM pg_database WHERE datname = '#{db_name}';")

        if String.contains?(output, db_name) do
          Logger.info("Database '#{db_name}' already exists")
          {:ok, db_name}
        else
          {output, status} =
            run_pg("createdb", [db_name], as_postgres_user: true)

          if status == 0 do
            Logger.info("Database '#{db_name}' created successfully")
            {:ok, db_name}
          else
            Logger.error("Failed to create database '#{db_name}': #{output}")
            {:error, output}
          end
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
    # Check using TCP connection
    run_pg("psql", ["-c", "SELECT 1"])
    |> case do
      {_, 0} -> true
      _ -> false
    end
  end

  def ensure_db_exists(name) do
    # Check if database exists
    {:ok, output} = run_sql("SELECT datname FROM pg_database WHERE datname = '#{name}';")

    if String.contains?(output, name) do
      Logger.info("Database '#{name}' already exists")
      {:ok, name}
    else
      Logger.info("Creating database '#{name}'")
      create_database(name)
    end
  end

  # Private functions

  defp do_initialize do
    # Run initdb
    args = ["--auth-host=trust", "--auth-local=trust", "-D", @pg_data_dir] ++ @pg_minimal_settings

    {output, status} =
      MuonTrap.cmd("/usr/bin/initdb", args, uid: postgres_uid, stderr_to_stdout: true)

    if status == 0 do
      Logger.info("PostgreSQL database initialized successfully")
      :ok
    else
      Logger.error("PostgreSQL database initialization failed: #{output}")
      {:error, output}
    end
  end

  defp ensure_dirs_permissions([], _uid, _gid), do: :ok

  defp ensure_dirs_permissions([dir | rest], uid, gid) do
    File.chown!(dir, uid)
    File.chgrp!(dir, gid)
    File.chmod!(dir, 0o770)

    {:ok, filelist} = File.ls!(dir)

    Enum.reduce(filelist, rest, fn file_or_dir, acc ->
      path = Path.join(dir, file_or_dir)

      if File.dir?(path) do
        [path | acc]
      else
        File.chown!(path, uid)
        File.chgrp!(path, gid)
        File.chmod!(path, 0o770)
        acc
      end
    end)
    |> ensure_dirs_permissions(uid, gid)
  end

  defp do_start do
    # Ensure the directory for data exists
    File.mkdir_p!(@pg_data_dir)
    File.mkdir_p!(@pg_run_dir)
    {postgres_uid_str, _} = MuonTrap.cmd("id", ["-u", @postgres_user], stderr_to_stdout: true)
    {postgres_gid_str, _} = MuonTrap.cmd("id", ["-g", @postgres_user], stderr_to_stdout: true)
    postgres_uid = String.trim(postgres_uid_str) |> String.to_integer()
    postgres_gid = String.trim(postgres_gid_str) |> String.to_integer()
    :file.change_owner(String.to_charlist(@pg_data_dir), postgres_uid, postgres_gid)
    File.chmod!(@pg_data_dir, 0o700)
    :file.change_owner(String.to_charlist(@pg_run_dir), postgres_uid, postgres_gid)
    File.chmod!(@pg_run_dir, 0o700)

    # Start PostgreSQL with TCP listening enabled
    args = [
      "-D",
      @pg_data_dir,
      "-l",
      "/dev/null",
      "-o",
      "#{Enum.join(@pg_minimal_settings, " ")} -c port=#{@pg_port} -c listen_addresses='localhost' -c log_destination=stderr",
      "start"
    ]

    {output, status} =
      MuonTrap.cmd(
        "/usr/bin/pg_ctl",
        args,
        uid: postgres_uid,
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

    {output, status} =
      MuonTrap.cmd(
        "/usr/bin/pg_ctl",
        args,
        uid: get_postgres_uid(),
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

  defp run_pg(tool, args, opts \\ []) do
    cmd_opts =
      Enum.reduce(opts, [stderr_to_stdout: true], fn
        {:as_postgres_user, true}, acc -> Keyword.put(acc, :uid, get_postgres_uid())
        _, acc -> acc
      end)

    {output, status} =
      MuonTrap.cmd(
        "/usr/bin/#{tool}",
        ["-U", @postgres_user, "-h", @pg_host, "-p", "#{@pg_port}"] ++ args,
        cmd_opts
      )
  end

  # Helper to get postgres user ID
  defp get_postgres_uid do
    {uid_str, 0} = MuonTrap.cmd("id", ["-u", @postgres_user], stderr_to_stdout: true)
    String.trim(uid_str) |> String.to_integer()
  end
end
