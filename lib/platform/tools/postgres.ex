defmodule Platform.Tools.Postgres do
  @moduledoc """
  Configurable PostgreSQL tools that wrap Platform.PgDb functionality.
  All configuration is passed as options rather than using hardcoded values.
  """
  require Logger

  @postgres_user "postgres"
  @pg_host "localhost"

  @pg_minimal_settings ~w[
    -c shared_buffers=400kB
    -c max_connections=15
    -c dynamic_shared_memory_type=mmap
    -c max_prepared_transactions=0
    -c max_locks_per_transaction=32
    -c max_files_per_process=64
    -c work_mem=1MB
    -c wal_level=logical
    -c listen_addresses=localhost
    -c unix_socket_directories=/tmp/pg_run
  ]

  @pg_run_dir "/tmp/pg_run"

  @doc """
  Initialize the PostgreSQL database with configurable options.

  ## Options
  - `:pg_dir` - Base directory for PostgreSQL data and run directories (required)
  """
  def initialize(opts) do
    pg_dir = Keyword.fetch!(opts, :pg_dir)
    pg_data_dir = Path.join(pg_dir, "data")

    File.mkdir_p!(pg_data_dir)
    File.mkdir_p!(@pg_run_dir)

    [pg_data_dir, @pg_run_dir]
    |> ensure_dirs_permissions(get_postgres_uid(), get_postgres_gid())

    File.chmod!(pg_dir, 0o755)

    initialized?(opts)
    |> go_on(fn
      true ->
        Logger.info("PostgreSQL database already initialized at #{pg_data_dir}")
        :ok

      false ->
        args =
          ["--auth-host=trust", "--auth-local=trust", "-D", pg_data_dir] ++
            @pg_minimal_settings

        Logger.info("Initializing PostgreSQL database at #{pg_data_dir}")
        run_pg("initdb", args, as_postgres_user: true)
    end)
    |> go_on(fn
      {_, 0} ->
        Logger.info("PostgreSQL database initialized successfully")
        :ok

      {output, _} ->
        Logger.error("PostgreSQL database initialization failed: #{output}")
        {:error, output}
    end)
  end

  @doc """
  Check if PostgreSQL is already initialized.

  ## Options
  - `:pg_dir` - Base directory for PostgreSQL data (required)
  """
  def initialized?(opts) do
    pg_dir = Keyword.fetch!(opts, :pg_dir)
    pg_data_dir = Path.join(pg_dir, "data")
    File.exists?(Path.join(pg_data_dir, "PG_VERSION"))
  end

  @doc """
  Start the PostgreSQL server with configurable options.

  ## Options
  - `:pg_dir` - Base directory for PostgreSQL data and run directories (required)
  - `:pg_port` - PostgreSQL port (default: 5432)
  """
  def start(opts) do
    pg_dir = Keyword.fetch!(opts, :pg_dir)
    pg_port = Keyword.get(opts, :pg_port, 5432)
    pg_data_dir = Path.join(pg_dir, "data")

    server_running?(opts)
    |> go_on(fn
      true ->
        Logger.info("PostgreSQL already running on port #{pg_port}")
        :ok

      false ->
        minimal_settings_str = Enum.join(@pg_minimal_settings, " ")

        args = [
          "-D",
          pg_data_dir,
          "-l",
          "/dev/null",
          "-o",
          "#{minimal_settings_str} -c port=#{pg_port} -c listen_addresses='localhost' -c log_destination=stderr",
          "start"
        ]

        Logger.info("Starting PostgreSQL server on port #{pg_port}")
        run_pg("pg_ctl", args, as_postgres_user: true)
    end)
    |> go_on(fn
      {output, status} when status != 0 ->
        Logger.error("PostgreSQL server failed to start: #{output}")
        {:error, output}

      {output, 0} ->
        Process.sleep(1000)
        {output, server_running?(opts)}
    end)
    |> go_on(fn
      {_, true} ->
        Logger.info("PostgreSQL server started successfully")
        :ok

      {output, false} ->
        Logger.error("PostgreSQL server failed to start: #{output}")
        {:error, output}
    end)
  end

  @doc """
  Stop the PostgreSQL server.

  ## Options
  - `:pg_dir` - Base directory for PostgreSQL data (required)
  """
  def stop(opts) do
    pg_dir = Keyword.fetch!(opts, :pg_dir)
    pg_data_dir = Path.join(pg_dir, "data")

    server_running?(opts)
    |> go_on(fn
      false ->
        Logger.info("PostgreSQL server not running")
        :ok

      true ->
        Logger.info("Stopping PostgreSQL server")
        args = ["-D", pg_data_dir, "stop", "-m", "fast"]

        run_pg("pg_ctl", args, as_postgres_user: true)
    end)
    |> go_on(fn
      {_, 0} ->
        Logger.info("PostgreSQL server stopped successfully")
        :ok

      {output, _} ->
        Logger.error("PostgreSQL server failed to stop: #{output}")
        {:error, output}
    end)
  end

  @doc """
  Run a SQL command against the PostgreSQL database.

  ## Options
  - `:pg_port` - PostgreSQL port (default: 5432)
  - `:db_name` - Database name (default: "postgres")
  """
  def run_sql(sql, opts \\ []) do
    pg_port = Keyword.get(opts, :pg_port, 5432)
    db_name = Keyword.get(opts, :db_name, "postgres")

    server_running?(opts)
    |> go_on(fn
      false ->
        Logger.error("Cannot run SQL: PostgreSQL server not running")
        {:error, "PostgreSQL server not running"}

      true ->
        Logger.debug("Running SQL: #{sql} on database #{db_name}")

        run_pg(
          "psql",
          ["-U", @postgres_user, "-h", @pg_host, "-p", "#{pg_port}", "-d", db_name, "-c", sql],
          as_postgres_user: true
        )
    end)
    |> go_on(fn
      {output, 0} -> {:ok, output}
      {output, _} -> {:error, output}
    end)
  end

  @doc """
  Create a new PostgreSQL database.

  ## Options
  - `:pg_port` - PostgreSQL port (default: 5432)
  """
  def create_database(db_name, opts \\ []) do
    pg_port = Keyword.get(opts, :pg_port, 5432)

    server_running?(opts)
    |> go_on(fn
      false ->
        Logger.error("Cannot create database: PostgreSQL server not running")
        {:error, "PostgreSQL server not running"}

      true ->
        {:ok, output} =
          run_sql("SELECT datname FROM pg_database WHERE datname = '#{db_name}';", opts)

        String.contains?(output, db_name)
    end)
    |> go_on(fn
      true ->
        Logger.info("Database '#{db_name}' already exists")
        {:ok, db_name}

      false ->
        Logger.info("Creating database: #{db_name}")

        run_pg(
          "createdb",
          ["-U", @postgres_user, "-h", @pg_host, "-p", "#{pg_port}", db_name],
          as_postgres_user: true
        )
    end)
    |> go_on(fn
      {_, 0} ->
        Logger.info("Database '#{db_name}' created successfully")
        {:ok, db_name}

      {output, _} ->
        Logger.error("Failed to create database '#{db_name}': #{output}")
        {:error, output}
    end)
  end

  @doc """
  Check if the PostgreSQL server is running.

  ## Options
  - `:pg_port` - PostgreSQL port (default: 5432)
  """
  def server_running?(opts \\ []) do
    pg_port = Keyword.get(opts, :pg_port, 5432)
    sql = "SELECT 1"

    {_, status} =
      run_pg("psql", ["-U", @postgres_user, "-h", @pg_host, "-p", "#{pg_port}", "-c", sql])

    status == 0
  end

  @doc """
  Ensure a database exists, creating it if necessary.

  ## Options
  - `:pg_port` - PostgreSQL port (default: 5432)
  """
  def ensure_db_exists(name, opts \\ []) do
    {:ok, output} = run_sql("SELECT datname FROM pg_database WHERE datname = '#{name}';", opts)

    if String.contains?(output, name) do
      Logger.info("Database '#{name}' already exists")
      {:ok, name}
    else
      Logger.info("Creating database '#{name}'")
      create_database(name, opts)
    end
  end

  @doc """
  Create a daemon specification for running PostgreSQL server under supervision.

  ## Options
  - `:pg_dir` - Base directory for PostgreSQL data and run directories (required)
  - `:pg_port` - PostgreSQL port (default: 5432)
  - `:name` - Name for the daemon process (default: :postgres_daemon)
  """
  def daemon_spec(opts) do
    pg_dir = Keyword.fetch!(opts, :pg_dir)
    pg_port = Keyword.get(opts, :pg_port, 5432)
    daemon_name = Keyword.get(opts, :name, :postgres_daemon)

    pg_data_dir = Path.join(pg_dir, "data")
    postgres_uid = get_postgres_uid()

    {MuonTrap.Daemon,
     [
       "/usr/bin/postgres",
       ["-D", pg_data_dir] ++
         @pg_minimal_settings ++
         ["-c", "port=#{pg_port}", "-c", "log_destination=stderr"],
       [
         stderr_to_stdout: true,
         log_output: :debug,
         uid: postgres_uid,
         name: daemon_name
       ]
     ]}
  end

  def get_postgres_uid do
    {uid_str, 0} = MuonTrap.cmd("id", ["-u", @postgres_user], stderr_to_stdout: true)
    String.trim(uid_str) |> String.to_integer()
  end

  def get_postgres_gid do
    {gid_str, 0} = MuonTrap.cmd("id", ["-g", @postgres_user], stderr_to_stdout: true)
    String.trim(gid_str) |> String.to_integer()
  end

  # Private helper functions

  defp ensure_dirs_permissions([], _uid, _gid), do: :ok

  defp ensure_dirs_permissions([dir | rest], uid, gid) do
    File.chown!(dir, uid)
    File.chgrp!(dir, gid)
    File.chmod!(dir, 0o750)

    {:ok, filelist} = File.ls(dir)

    Enum.reduce(filelist, rest, fn file_or_dir, acc ->
      path = Path.join(dir, file_or_dir)

      if File.dir?(path) do
        [path | acc]
      else
        File.chown!(path, uid)
        File.chgrp!(path, gid)
        File.chmod!(path, 0o750)
        acc
      end
    end)
    |> ensure_dirs_permissions(uid, gid)
  end

  defp run_pg(tool, args, opts \\ []) do
    cmd_opts =
      Enum.reduce(opts, [stderr_to_stdout: true], fn
        {:as_postgres_user, true}, acc -> Keyword.put(acc, :uid, get_postgres_uid())
        _, acc -> acc
      end)

    MuonTrap.cmd("/usr/bin/#{tool}", args, cmd_opts)
  end

  defp go_on(data, step_fn) do
    case data do
      {:error, _} -> data
      {:ok, _} -> data
      :ok -> data
      _ -> step_fn.(data)
    end
  end
end
