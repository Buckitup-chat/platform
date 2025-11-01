defmodule Platform.Tools.Postgres do
  @moduledoc """
  Configurable PostgreSQL tools that wrap Platform.PgDb functionality.
  All configuration is passed as options rather than using hardcoded values.
  """
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
  def initialize(opts) do
    pg_dir = Keyword.fetch!(opts, :pg_dir)
    pg_data_dir = Path.join(pg_dir, "data")

    log(["[intialize] pg_data_dir: ", pg_data_dir], :debug)
    File.mkdir_p!(pg_data_dir)
    log(["[initialize] ", "dir created"], :debug)

    [pg_data_dir]
    |> ensure_dirs_permissions(get_postgres_uid(), get_postgres_gid())

    log(["[initialize] ", "permissions set"], :debug)

    File.chmod!(pg_dir, 0o755)
    log(["[initialize] ", "dir permissions set"], :debug)

    initialized?(opts)
    |> go_on(fn
      true ->
        ["database already initialized at ", pg_data_dir] |> log(:info)
        :ok

      false ->
        args =
          ["--auth-host=trust", "--auth-local=trust", "-D", pg_data_dir] ++
            @pg_minimal_settings

        ["Initializing PostgreSQL database at ", pg_data_dir] |> log(:info)
        run_pg("initdb", args, as_postgres_user: true)
    end)
    |> go_on(fn
      {_, 0} ->
        ["PostgreSQL database initialized successfully"] |> log(:info)
        :ok

      {output, _} ->
        ["PostgreSQL database initialization failed: ", output] |> log(:error)
        {:error, output}
    end)
  end

  def make_accessible(path) do
    uid = get_postgres_uid()
    gid = get_postgres_gid()

    [path] |> ensure_dirs_permissions(uid, gid)
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
         @pg_recovery_optimized_settings ++
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

  defp ensure_dirs_permissions([], _uid, _gid), do: :ok

  defp ensure_dirs_permissions(dirs, uid, gid) when is_list(dirs) do
    # Process directories in parallel
    dirs
    |> Task.async_stream(
      fn dir ->
        set_permissions(dir, uid, gid, 0o700)

        {:ok, filelist} = File.ls(dir)

        Enum.reduce(filelist, [], fn file_or_dir, acc ->
          path = Path.join(dir, file_or_dir)

          if File.dir?(path) do
            [path | acc]
          else
            set_permissions(path, uid, gid, 0o600)
            acc
          end
        end)
      end,
      max_concurrency: System.schedulers_online(),
      timeout: :infinity
    )
    |> Enum.reduce([], fn {:ok, subdirs}, acc -> subdirs ++ acc end)
    |> ensure_dirs_permissions(uid, gid)
  end

  defp set_permissions(path, uid, gid, mod) do
    with {:ok, info} <- File.stat(path),
         change_uid? <- info.uid != uid,
         change_gid? <- info.gid != gid,
         change_mod? <- rem(info.mode, 0o1000) != mod,
         true <- change_uid? || change_gid? || change_mod?,
         log([path, " ", inspect(info), " -> ", inspect({uid, gid, mod})], :debug) do
      track(change_uid?, fn -> File.chown!(path, uid) end)
      track(change_gid?, fn -> File.chgrp!(path, gid) end)
      track(change_mod?, fn -> File.chmod!(path, mod) end)
    end
  end

  defp track(predicate, fun) do
    if predicate do
      :timer.tc(fun)
      |> inspect()
      |> log(:debug)
    end
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

  defp log(msg, level), do: Platform.Log.postgres_log(msg, level)
end
