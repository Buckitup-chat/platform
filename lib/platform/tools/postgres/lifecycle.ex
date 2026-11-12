defmodule Platform.Tools.Postgres.Lifecycle do
  @moduledoc """
  PostgreSQL server lifecycle management.
  Handles startup, shutdown, and runtime directory management.

  Initialization is in `Platform.Tools.Postgres.Lifecycle.Init`.
  Cleanup is in `Platform.Tools.Postgres.Lifecycle.Cleanup`.
  """
  use Toolbox.OriginLog

  import Toolbox.Flow, only: [go_on: 2]

  alias Platform.Tools.Postgres.Permissions

  @postgres_user "postgres"
  @pg_host "localhost"
  @default_pg_port 5432

  # MuonTrap.cmd/3 blocks in a receive with no way out, and pg tools are invoked
  # inline from boot-stage GenServers: one unbounded call wedges staged startup
  # forever. Every invocation is time-boxed unless the caller asks for more.
  @default_cmd_timeout :timer.seconds(60)
  @base_cmd_opts [stderr_to_stdout: true, timeout: @default_cmd_timeout]

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
    -c wal_sender_timeout=600s
    -c tcp_keepalives_idle=60
    -c tcp_keepalives_interval=10
    -c tcp_keepalives_count=5
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
    -c statement_timeout=45s
    -c idle_in_transaction_session_timeout=60s
  ]

  # --- Delegated Init functions ---

  defdelegate initialize(opts, retries \\ 5), to: __MODULE__.Init
  defdelegate initialized?(opts), to: __MODULE__.Init
  defdelegate valid_init?(opts), to: __MODULE__.Init
  defdelegate clean_data_dir(opts), to: __MODULE__.Init

  # --- Delegated Cleanup functions ---

  defdelegate cleanup_old_server(pg_dir, opts \\ []), to: __MODULE__.Cleanup
  defdelegate remove_stale_postmaster_pid(pg_dir), to: __MODULE__.Cleanup

  # --- Delegated RunDir functions ---

  defdelegate ensure_run_dir(pg_dir, opts \\ []), to: __MODULE__.RunDir
  defdelegate cleanup_run_dir_files(run_dir), to: __MODULE__.RunDir
  defdelegate extract_pg_run_dir(pg_dir, opts \\ []), to: __MODULE__.RunDir

  # --- Server start/stop ---

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
    pg_port = Keyword.get(opts, :pg_port, @default_pg_port)

    check_if_running = fn
      true ->
        ["PostgreSQL already running on port ", pg_port] |> log(:info)
        :ok

      false ->
        start_pg_server(opts)
    end

    evaluate_pg_ctl_output = fn
      {output, status} when status != 0 ->
        ["PostgreSQL server failed to start: ", output] |> log(:error)
        {:error, output}

      {output, 0} ->
        Process.sleep(1000)
        {output, server_running?(opts)}
    end

    confirm_server_running = fn
      {_, true} ->
        ["PostgreSQL server started successfully"] |> log(:info)
        :ok

      {output, false} ->
        ["PostgreSQL server failed to start: ", output] |> log(:error)
        {:error, output}
    end

    server_running?(opts)
    |> go_on(check_if_running)
    |> go_on(evaluate_pg_ctl_output)
    |> go_on(confirm_server_running)
  end

  defp start_pg_server(opts) do
    pg_dir = Keyword.fetch!(opts, :pg_dir)
    pg_port = Keyword.get(opts, :pg_port, @default_pg_port)
    pg_data_dir = Path.join(pg_dir, "data")
    run_dir = extract_pg_run_dir(pg_dir, opts)

    settings = Enum.join(@pg_minimal_settings ++ @pg_recovery_optimized_settings, " ")

    args = [
      "-D",
      pg_data_dir,
      "-l",
      "/dev/null",
      "-o",
      "#{settings} -c port=#{pg_port} -c listen_addresses='localhost' -c log_destination=stderr",
      "start"
    ]

    ["Starting PostgreSQL server on port ", pg_port, " with run_dir ", run_dir]
    |> log(:info)

    run_pg("pg_ctl", args, as_postgres_user: true, run_dir: run_dir)
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

    check_if_running = fn
      false ->
        ["PostgreSQL server not running"] |> log(:info)
        :ok

      true ->
        ["Stopping PostgreSQL server with run_dir ", run_dir] |> log(:info)

        run_pg("pg_ctl", ["-D", pg_data_dir, "stop", "-m", "fast"],
          as_postgres_user: true,
          run_dir: run_dir
        )
    end

    report_stop = fn
      {_, 0} ->
        ["PostgreSQL server stopped successfully"] |> log(:info)
        :ok

      {output, _} ->
        ["PostgreSQL server failed to stop: ", output] |> log(:error)
        {:error, output}
    end

    server_running?(opts)
    |> go_on(check_if_running)
    |> go_on(report_stop)
  end

  @doc """
  Check if the PostgreSQL server is running.

  ## Options
  - `:pg_port` - PostgreSQL port (default: 5432)
  """
  def server_running?(opts \\ []) do
    pg_port = Keyword.get(opts, :pg_port, @default_pg_port)

    # psql is probed as a liveness check, so any failure to even run it — a missing
    # binary, a raising uid lookup, a timeout — just means "not running".
    try do
      run_pg("psql", ["-U", @postgres_user, "-h", @pg_host, "-p", "#{pg_port}", "-c", "SELECT 1"])
      |> then(&match?({_, 0}, &1))
    catch
      _, _ -> false
    end
  end

  # --- Settings accessors ---

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

  # --- Shared pg command runner ---

  @doc false
  def run_pg(tool, args, opts \\ []) do
    cmd_opts = Enum.reduce(opts, @base_cmd_opts, &apply_pg_opt/2)

    MuonTrap.cmd("/usr/bin/#{tool}", args, cmd_opts)
    |> tap(&log_timeout(&1, tool, Keyword.fetch!(cmd_opts, :timeout)))
  end

  defp apply_pg_opt(opt, cmd_opts) do
    case opt do
      {:as_postgres_user, true} ->
        cmd_opts
        |> Keyword.put(:uid, get_postgres_uid())
        |> Keyword.put(:gid, get_postgres_gid())

      {:run_dir, run_dir} ->
        Keyword.update(cmd_opts, :env, [{"PGHOST", run_dir}], &[{"PGHOST", run_dir} | &1])

      {:timeout, ms} ->
        Keyword.put(cmd_opts, :timeout, ms)

      _other ->
        cmd_opts
    end
  end

  defp log_timeout({_output, :timeout}, tool, timeout_ms),
    do: [tool, " timed out after ", to_string(timeout_ms), "ms"] |> log(:error)

  defp log_timeout(_result, _tool, _timeout_ms), do: :ok
end
