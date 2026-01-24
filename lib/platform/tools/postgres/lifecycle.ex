defmodule Platform.Tools.Postgres.Lifecycle do
  @moduledoc """
  PostgreSQL server lifecycle management.
  Handles initialization, startup, shutdown, and runtime directory management.
  """
  use Toolbox.OriginLog

  import Toolbox.Flow, only: [go_on: 2]

  alias Platform.Tools.Postgres.{Permissions, SharedMemory}
  alias Platform.Tools.OsPid

  @postgres_user "postgres"
  @pg_host "localhost"
  @pg_run_dir "/tmp/pg_run"

  @pg_minimal_settings ~w[
    -c shared_buffers=400kB
    -c max_connections=50
    -c dynamic_shared_memory_type=posix
    -c max_prepared_transactions=0
    -c max_locks_per_transaction=32
    -c max_files_per_process=64
    -c work_mem=1MB
    -c wal_level=logical
    -c listen_addresses=localhost
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
    run_dir = ensure_run_dir(pg_dir, opts)

    log(["[intialize] pg_data_dir: ", pg_data_dir, ", run_dir: ", run_dir], :debug)
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

        ["Initializing PostgreSQL database at ", pg_data_dir, " with run_dir ", run_dir]
        |> log(:info)

        run_pg("initdb", args, as_postgres_user: true, run_dir: run_dir)
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
        Platform.Tools.Postgres.Database.setup_replication(opts)
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
    run_dir = extract_pg_run_dir(pg_dir, opts)

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

        ["Starting PostgreSQL server on port ", pg_port, " with run_dir ", run_dir]
        |> log(:info)

        run_pg("pg_ctl", args, as_postgres_user: true, run_dir: run_dir)
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
    run_dir = extract_pg_run_dir(pg_dir, opts)

    server_running?(opts)
    |> go_on(fn
      false ->
        ["PostgreSQL server not running"] |> log(:info)
        :ok

      true ->
        ["Stopping PostgreSQL server with run_dir ", run_dir] |> log(:info)
        args = ["-D", pg_data_dir, "stop", "-m", "fast"]

        run_pg("pg_ctl", args, as_postgres_user: true, run_dir: run_dir)
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
  Ensure the PostgreSQL run directory exists with correct permissions.

  ## Options
  - `:pg_dir` - Base directory for PostgreSQL data (required)
  - `:run_dir` - Override run directory path (optional)
  - `:device` - Device name for run directory (optional)

  ## Returns
  The run directory path.
  """
  def ensure_run_dir(pg_dir, opts \\ []) do
    run_dir = extract_pg_run_dir(pg_dir, opts)

    File.mkdir_p!(run_dir)

    parent_dir = Path.dirname(run_dir)
    File.chmod!(parent_dir, 0o755)

    [run_dir]
    |> Permissions.ensure_dirs(get_postgres_uid(), get_postgres_gid())

    cleanup_run_dir_files(run_dir)

    run_dir
  end

  @doc """
  Clean all files in the PostgreSQL run directory.
  """
  def cleanup_run_dir_files(run_dir) do
    with {:ok, entries} <- File.ls(run_dir) do
      Enum.each(entries, fn entry ->
        Path.join(run_dir, entry)
        |> File.rm()
      end)
    end

    :ok
  end

  @doc """
  Remove stale postmaster.pid file if the process is not running.
  """
  def remove_stale_postmaster_pid(pg_dir) do
    pid_path = Path.join([pg_dir, "data", "postmaster.pid"])

    with true <- File.exists?(pid_path),
         {:ok, contents} <- File.read(pid_path),
         [first_line | _] <- String.split(contents, "\n", trim: true),
         os_pid when not is_nil(os_pid) <- parse_os_pid(first_line),
         false <- os_pid_alive?(os_pid) do
      File.rm(pid_path)
    end

    :ok
  end

  @doc """
  Clean up any existing PostgreSQL server before starting a new one.

  ## Options
  - `:pg_dir` - Base directory for PostgreSQL data (required)

  ## Returns
  `:ok` after cleanup attempt
  """
  def cleanup_old_server(pg_dir, opts \\ []) do
    pg_data_dir = Path.join(pg_dir, "data")
    run_dir = extract_pg_run_dir(pg_dir, opts)

    [
      "Attempting to stop any existing PostgreSQL server for ",
      pg_data_dir,
      " (run_dir: ",
      run_dir,
      ")"
    ]
    |> log(:info)

    {output, status} =
      run_pg("pg_ctl", ["-D", pg_data_dir, "stop", "-m", "fast"],
        as_postgres_user: true,
        run_dir: run_dir
      )

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

    run_dir = ensure_run_dir(pg_dir, opts)
    remove_stale_postmaster_pid(run_dir)

    :ok
  end

  @doc """
  Extract the PostgreSQL run directory path from options.
  """
  def extract_pg_run_dir(pg_dir, opts \\ []) do
    cond do
      run_dir = Keyword.get(opts, :run_dir) ->
        run_dir

      device = Keyword.get(opts, :device) ->
        Path.join(@pg_run_dir, device)

      true ->
        device =
          case String.split(pg_dir, "/", trim: true) do
            ["root", "media", device | _] -> device
            _ -> "internal"
          end

        Path.join(@pg_run_dir, device)
    end
  end

  @doc """
  Get the settings for PostgreSQL minimal configuration.
  """
  def minimal_settings, do: @pg_minimal_settings

  @doc """
  Get the settings for PostgreSQL recovery optimization.
  """
  def recovery_optimized_settings, do: @pg_recovery_optimized_settings

  @doc """
  Get the postgres user name.
  """
  def postgres_user, do: @postgres_user

  defdelegate get_postgres_uid(), to: Permissions, as: :get_uid
  defdelegate get_postgres_gid(), to: Permissions, as: :get_gid

  defp parse_os_pid(nil), do: nil

  defp parse_os_pid(str) do
    str
    |> String.trim()
    |> Integer.parse()
    |> case do
      {os_pid, _} when os_pid > 0 -> os_pid
      _ -> nil
    end
  end

  defp os_pid_alive?(os_pid) when is_integer(os_pid) do
    OsPid.alive?(os_pid)
  end

  defp run_pg(tool, args, opts \\ []) do
    cmd_opts =
      Enum.reduce(opts, [stderr_to_stdout: true], fn
        {:as_postgres_user, true}, acc ->
          acc
          |> Keyword.put(:uid, get_postgres_uid())
          |> Keyword.put(:gid, get_postgres_gid())

        {:run_dir, run_dir}, acc ->
          # Set PGHOST to run_dir so pg_* tools use the correct socket directory
          env = Keyword.get(acc, :env, [])
          Keyword.put(acc, :env, [{"PGHOST", run_dir} | env])

        _, acc ->
          acc
      end)

    MuonTrap.cmd("/usr/bin/#{tool}", args, cmd_opts)
  end
end
