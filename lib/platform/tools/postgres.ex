defmodule Platform.Tools.Postgres do
  @moduledoc """
  Configurable PostgreSQL tools that wrap Platform.PgDb functionality.
  All configuration is passed as options rather than using hardcoded values.
  """
  alias Platform.Tools.Postgres.{Permissions, SharedMemory}
  @postgres_user "postgres"
  @pg_host "localhost"

  @pg_minimal_settings ~w[
    -c shared_buffers=400kB
    -c max_connections=15
    -c dynamic_shared_memory_type=posix
    -c max_prepared_transactions=0
    -c max_locks_per_transaction=32
    -c max_files_per_process=64
    -c work_mem=1MB
    -c wal_level=logical
    -c listen_addresses=localhost
    -c unix_socket_directories=/tmp/pg_run
  ]

  # Settings optimized for faster recovery on SD cards
  # 90% focus on speed/absence of recovery, 10% on embedded constraints
  # Key optimizations:
  # - 5min checkpoints (vs 30min) = 6x faster recovery, max ~5min WAL replay
  # - 256MB WAL (vs 1GB) = 4x less data to replay on recovery
  # - Aggressive WAL/bgwriter = data persisted faster, less recovery needed
  # - Balanced for SD card wear (not too aggressive on checkpoints)
  @pg_recovery_optimized_settings ~w[
    -c checkpoint_timeout=5min
    -c checkpoint_completion_target=0.9
    -c max_wal_size=256MB
    -c min_wal_size=64MB
    -c wal_compression=on
    -c full_page_writes=off
    -c fsync=off
    -c synchronous_commit=off
    -c wal_writer_delay=200ms
    -c checkpoint_warning=30s
    -c wal_sync_method=fdatasync
    -c wal_buffers=256kB
    -c bgwriter_delay=500ms
    -c bgwriter_lru_maxpages=100
  ]

  @doc """
  Initialize the PostgreSQL database with configurable options.

  ## Options
  - `:pg_dir` - Base directory for PostgreSQL data and run directories (required)

  ## Returns
  - `:ok` if the PostgreSQL database was initialized successfully
  - `{:error, output}` if the PostgreSQL database failed to initialize
  """
  def initialize(opts, retries \\ 5) do
    pg_dir = Keyword.fetch!(opts, :pg_dir)
    pg_data_dir = Path.join(pg_dir, "data")

    log(["[intialize] pg_data_dir: ", pg_data_dir], :debug)
    File.mkdir_p!(pg_data_dir)
    log(["[initialize] ", "dir created"], :debug)

    Permissions.log_permission_issues(pg_data_dir)

    [pg_data_dir]
    |> Permissions.ensure_dirs(Permissions.get_uid(), Permissions.get_gid())

    log(["[initialize] ", "permissions set"], :debug)

    File.chmod!(pg_dir, 0o755)
    log(["[initialize] ", "dir permissions set"], :debug)

    {initialized?(opts), valid_init?(opts)}
    |> go_on(fn
      {true, true} ->
        ["database already initialized at ", pg_data_dir] |> log(:info)
        :ok

      {true, false} ->
        [
          "CRITICAL: PostgreSQL data directory exists but is INVALID at ",
          pg_data_dir,
          " - may contain user data, skipping re-initialization"
        ]
        |> log(:critical)

        {:error, :incorrectly_initialized}

      {false, _} ->
        SharedMemory.cleanup_stale(pg_data_dir)

        args =
          ["--auth-host=trust", "--auth-local=trust", "-D", pg_data_dir] ++
            @pg_minimal_settings

        ["Initializing PostgreSQL database at ", pg_data_dir] |> log(:info)
        run_pg("initdb", args, as_postgres_user: true)
    end)
    |> go_on(fn
      {output, code} when code != 0 ->
        ["PostgreSQL database initialization failed: ", output] |> log(:error)
        {:error, output}

      {_, 0} ->
        valid_init?(opts)
    end)
    |> go_on(fn
      true ->
        setup_replication(opts)
        :ok

      false ->
        retries - 1
    end)
    |> go_on(fn
      retries_left when retries_left < 1 ->
        ["PostgreSQL initialization failed after retries"] |> log(:error)
        {:error, :failed_after_retries}

      retries_left ->
        ["PostgreSQL initialization produced invalid data directory, cleaning and retrying"]
        |> log(:warning)

        clean_data_dir(opts)
        initialize(opts, retries_left)
    end)
  end

  @doc """
  Configure pg_hba.conf for replication connections using the postgres superuser.
  This should be called after PostgreSQL initialization.

  ## Options
  - `:pg_dir` - Base directory for PostgreSQL data (required)
  - `:pg_port` - PostgreSQL port (default: 5432)

  ## Returns
  - `:ok` if replication setup was successful
  - `{:error, reason}` if setup failed
  """
  def setup_replication(opts) do
    pg_dir = Keyword.fetch!(opts, :pg_dir)
    pg_port = Keyword.get(opts, :pg_port, 5432)
    pg_data_dir = Path.join(pg_dir, "data")

    ["Setting up replication configuration"] |> log(:info)

    # Update pg_hba.conf to allow replication connections
    hba_result = update_pg_hba_conf(pg_data_dir)

    case hba_result do
      :ok ->
        if server_running?(opts) do
          # Reload PostgreSQL configuration if running
          case run_sql("SELECT pg_reload_conf();", pg_port: pg_port) do
            {:ok, _} ->
              ["Replication configuration setup successfully"] |> log(:info)
              :ok

            {:error, reason} ->
              ["Failed to reload PostgreSQL configuration: ", reason] |> log(:error)
              {:error, "Failed to reload configuration: #{reason}"}
          end
        else
          ["Replication configuration set (will apply on next start)"] |> log(:info)
          :ok
        end

      {:error, reason} ->
        log(["Failed to update pg_hba.conf: ", reason], :error)
        {:error, "Failed to update pg_hba.conf: #{reason}"}
    end
  end

  @doc """
  Update pg_hba.conf to allow replication connections.

  ## Parameters
  - `pg_data_dir` - PostgreSQL data directory path

  ## Returns
  - `:ok` if pg_hba.conf was updated successfully
  - `{:error, reason}` if update failed
  """
  def update_pg_hba_conf(pg_data_dir) do
    hba_file = Path.join(pg_data_dir, "pg_hba.conf")

    case File.read(hba_file) do
      {:ok, content} ->
        # Check if replication entry already exists
        if String.contains?(content, "# Replication connections") do
          ["pg_hba.conf already configured for replication"] |> log(:debug)
          :ok
        else
          # Add replication entries for postgres superuser
          replication_entries = """

          # Replication connections
          host    replication     #{@postgres_user}     127.0.0.1/32            trust
          host    replication     #{@postgres_user}     ::1/128                 trust
          local   replication     #{@postgres_user}                             trust
          """

          new_content = content <> replication_entries

          case File.write(hba_file, new_content) do
            :ok ->
              ["pg_hba.conf updated for replication connections"] |> log(:info)
              :ok

            {:error, reason} ->
              {:error, "Failed to write pg_hba.conf: #{inspect(reason)}"}
          end
        end

      {:error, reason} ->
        {:error, "Failed to read pg_hba.conf: #{inspect(reason)}"}
    end
  end

  defdelegate make_accessible(path), to: Permissions

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
  Validate that a PostgreSQL data directory is properly initialized.
  Checks for essential files and directories that must exist after a successful initdb.

  ## Options
  - `:pg_dir` - Base directory for PostgreSQL data (required)

  ## Returns
  - `true` if the data directory appears valid
  - `false` if essential components are missing
  """
  def valid_init?(opts) do
    pg_dir = Keyword.fetch!(opts, :pg_dir)
    pg_data_dir = Path.join(pg_dir, "data")

    required_paths = [
      Path.join(pg_data_dir, "PG_VERSION"),
      Path.join(pg_data_dir, "base/1"),
      Path.join(pg_data_dir, "global"),
      Path.join(pg_data_dir, "pg_hba.conf")
    ]

    Enum.all?(required_paths, &File.exists?/1)
  end

  @doc """
  Clean the PostgreSQL data directory for re-initialization.

  ## Options
  - `:pg_dir` - Base directory for PostgreSQL data (required)

  ## Returns
  - `:ok` if cleanup was successful
  - `{:error, reason}` if cleanup failed
  """
  def clean_data_dir(opts) do
    pg_dir = Keyword.fetch!(opts, :pg_dir)
    pg_data_dir = Path.join(pg_dir, "data")

    ["Cleaning PostgreSQL data directory: ", pg_data_dir] |> log(:warning)

    case File.rm_rf(pg_data_dir) do
      {:ok, _} ->
        ["PostgreSQL data directory cleaned"] |> log(:info)
        :ok

      {:error, reason, path} ->
        ["Failed to clean PostgreSQL data directory: ", inspect(reason), " at ", path]
        |> log(:error)

        {:error, reason}
    end
  end

  @doc """
  Start the PostgreSQL server with configurable options.

  ## Options
  - `:pg_dir` - Base directory for PostgreSQL data and run directories (required)
  - `:pg_port` - PostgreSQL port (default: 5432)

  ## Returns
  - `:ok` if the PostgreSQL server was started successfully
  - `{:error, output}` if the PostgreSQL server failed to start
  """
  def start(opts) do
    pg_dir = Keyword.fetch!(opts, :pg_dir)
    pg_port = Keyword.get(opts, :pg_port, 5432)
    pg_data_dir = Path.join(pg_dir, "data")

    server_running?(opts)
    |> go_on(fn
      true ->
        ["PostgreSQL already running on port ", pg_port] |> log(:info)
        :ok

      false ->
        minimal_settings_str = Enum.join(@pg_minimal_settings, " ")
        recovery_settings_str = Enum.join(@pg_recovery_optimized_settings, " ")

        args = [
          "-D",
          pg_data_dir,
          "-l",
          "/dev/null",
          "-o",
          "#{minimal_settings_str} #{recovery_settings_str} -c port=#{pg_port} -c listen_addresses='localhost' -c log_destination=stderr",
          "start"
        ]

        ["Starting PostgreSQL server on port ", pg_port] |> log(:info)
        run_pg("pg_ctl", args, as_postgres_user: true)
    end)
    |> go_on(fn
      {output, status} when status != 0 ->
        ["PostgreSQL server failed to start: ", output] |> log(:error)
        {:error, output}

      {output, 0} ->
        Process.sleep(1000)
        {output, server_running?(opts)}
    end)
    |> go_on(fn
      {_, true} ->
        ["PostgreSQL server started successfully"] |> log(:info)
        :ok

      {output, false} ->
        ["PostgreSQL server failed to start: ", output] |> log(:error)
        {:error, output}
    end)
  end

  @doc """
  Stop the PostgreSQL server.

  ## Options
  - `:pg_dir` - Base directory for PostgreSQL data (required)

  ## Returns
  - `:ok` if the PostgreSQL server was stopped successfully
  - `{:error, output}` if the PostgreSQL server failed to stop
  """
  def stop(opts) do
    pg_dir = Keyword.fetch!(opts, :pg_dir)
    pg_data_dir = Path.join(pg_dir, "data")

    server_running?(opts)
    |> go_on(fn
      false ->
        ["PostgreSQL server not running"] |> log(:info)
        :ok

      true ->
        ["Stopping PostgreSQL server"] |> log(:info)
        args = ["-D", pg_data_dir, "stop", "-m", "fast"]

        run_pg("pg_ctl", args, as_postgres_user: true)
    end)
    |> go_on(fn
      {_, 0} ->
        ["PostgreSQL server stopped successfully"] |> log(:info)
        :ok

      {output, _} ->
        ["PostgreSQL server failed to stop: ", output] |> log(:error)
        {:error, output}
    end)
  end

  @doc """
  Run a SQL command against the PostgreSQL database.

  ## Options
  - `:pg_port` - PostgreSQL port (default: 5432)
  - `:db_name` - Database name (default: "postgres")

  ## Returns
  - `{:ok, output}` if the SQL command was executed successfully
  - `{:error, output}` if the SQL command failed
  """
  def run_sql(sql, opts \\ []) do
    pg_port = Keyword.get(opts, :pg_port, 5432)
    db_name = Keyword.get(opts, :db_name, "postgres")

    server_running?(opts)
    |> go_on(fn
      false ->
        ["Cannot run SQL: PostgreSQL server not running"] |> log(:error)
        {:error, "PostgreSQL server not running"}

      true ->
        ["Running SQL: #{sql} on database #{db_name}"] |> log(:debug)

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

  ## Returns
  - `{:ok, db_name}` if the database was created successfully
  - `{:error, output}` if the database failed to create
  - `{:error, "PostgreSQL server not running"}` if the PostgreSQL server is not running
  """
  def create_database(db_name, opts \\ []) do
    pg_port = Keyword.get(opts, :pg_port, 5432)

    server_running?(opts)
    |> go_on(fn
      false ->
        ["Cannot create database: PostgreSQL server not running"] |> log(:error)
        {:error, "PostgreSQL server not running"}

      true ->
        {:ok, output} =
          run_sql("SELECT datname FROM pg_database WHERE datname = '#{db_name}';", opts)

        String.contains?(output, db_name)
    end)
    |> go_on(fn
      true ->
        ["Database '#{db_name}' already exists"] |> log(:info)
        {:ok, db_name}

      false ->
        ["Creating database: #{db_name}"] |> log(:info)

        run_pg(
          "createdb",
          ["-U", @postgres_user, "-h", @pg_host, "-p", "#{pg_port}", db_name],
          as_postgres_user: true
        )
    end)
    |> go_on(fn
      {_, 0} ->
        ["Database '#{db_name}' created successfully"] |> log(:info)
        {:ok, db_name}

      {output, _} ->
        ["Failed to create database '#{db_name}': #{output}"] |> log(:error)
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
  Build a PostgreSQL connection string from an Ecto repo configuration.

  ## Parameters
  - `repo` - An Ecto repository module
  - `opts` - Optional keyword list with overrides:
    - `:port` - Override the port from repo config (useful for dynamically started repos)

  ## Returns
  A connection string in the format: "host=... port=... dbname=... user=... password=..."
  """
  def build_connection_string(repo, opts \\ []) do
    config = repo.config()
    host = Keyword.get(config, :hostname, "localhost")
    # Allow port override for dynamically started repos
    port = Keyword.get(opts, :port) || Keyword.get(config, :port, 5432)
    database = Keyword.get(config, :database, "chat")
    username = Keyword.get(config, :username, "postgres")
    password = Keyword.get(config, :password, "")

    "host=#{host} port=#{port} dbname=#{database} user=#{username} password=#{password}"
  end

  @doc """
  Ensure a database exists, creating it if necessary.

  ## Options
  - `:pg_port` - PostgreSQL port (default: 5432)

  ## Returns
  - `{:ok, db_name}` if the database exists
  - `{:error, output}` if the database does not exist
  """
  def ensure_db_exists(name, opts \\ []) do
    {:ok, output} = run_sql("SELECT datname FROM pg_database WHERE datname = '#{name}';", opts)

    if String.contains?(output, name) do
      ["Database '#{name}' already exists"] |> log(:info)
      {:ok, name}
    else
      ["Creating database '#{name}'"] |> log(:info)
      create_database(name, opts)
    end
  end

  def cleanup_old_server(pg_dir) do
    pg_data_dir = Path.join(pg_dir, "data")

    ["Attempting to stop any existing PostgreSQL server for ", pg_data_dir]
    |> log(:info)

    {output, status} =
      run_pg("pg_ctl", ["-D", pg_data_dir, "stop", "-m", "fast"], as_postgres_user: true)

    if status == 0 do
      ["Existing PostgreSQL server stopped before daemon start"] |> log(:info)
    else
      ["pg_ctl stop exited with status ", to_string(status), ": ", output]
      |> log(:warning)
    end

    if File.exists?("/usr/bin/lsipc") do
      {ipc_output, ipc_status} = MuonTrap.cmd("/usr/bin/lsipc", ["-m"], stderr_to_stdout: true)

      [
        "lsipc -m exited with status ",
        to_string(ipc_status),
        ":\n",
        ipc_output
      ]
      |> log(:debug)
    end

    SharedMemory.cleanup_stale(pg_data_dir)

    :ok
  end

  defdelegate cleanup_stale_shared_memory(pg_data_dir), to: SharedMemory, as: :cleanup_stale
  defdelegate cleanup_posix_shared_memory(), to: SharedMemory, as: :cleanup_posix

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

    {MuonTrap.Daemon,
     [
       "/usr/bin/postgres",
       ["-D", pg_data_dir] ++
         @pg_minimal_settings ++
         @pg_recovery_optimized_settings ++
         ["-c", "port=#{pg_port}", "-c", "log_destination=stderr"],
       [
         stderr_to_stdout: true,
         log_output: :debug,
         uid: get_postgres_uid(),
         gid: get_postgres_gid(),
         name: daemon_name
       ]
     ]}
  end

  defdelegate get_postgres_uid(), to: Permissions, as: :get_uid
  defdelegate get_postgres_gid(), to: Permissions, as: :get_gid

  @doc """
  Get replication user credentials.

  ## Returns
  A keyword list with `:username` for the postgres superuser (no password needed with trust auth).
  """
  def replication_credentials do
    [username: @postgres_user]
  end

  defp run_pg(tool, args, opts \\ []) do
    cmd_opts =
      Enum.reduce(opts, [stderr_to_stdout: true], fn
        {:as_postgres_user, true}, acc ->
          acc
          |> Keyword.put(:uid, get_postgres_uid())
          |> Keyword.put(:gid, get_postgres_gid())

        _, acc ->
          acc
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

  defp log(msg, level), do: Platform.Log.postgres_log(msg, level)
end
