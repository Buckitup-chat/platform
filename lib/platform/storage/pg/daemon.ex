defmodule Platform.Storage.Pg.Daemon do
  @moduledoc """
  PostgreSQL daemon supervision stage.
  Starts the PostgreSQL server daemon, waits for it to be ready,
  then starts the next stage.
  """
  use GracefulGenServer, timeout: :timer.minutes(3)
  use Toolbox.OriginLog

  alias Platform.Tools.Postgres

  # Increased from 10 to 30 attempts (60 seconds total) for slow SD cards
  @max_startup_attempts 30
  @startup_check_interval_ms 2000

  @impl true
  def on_init(opts) do
    next = opts |> Keyword.fetch!(:next)

    %{
      pg_dir: opts |> Keyword.fetch!(:pg_dir),
      pg_port: opts |> Keyword.fetch!(:pg_port),
      device: Keyword.get(opts, :device),
      daemon_name: Keyword.get(opts, :name, :postgres_daemon),
      task_supervisor: opts |> Keyword.fetch!(:task_in),
      next_specs: next |> Keyword.fetch!(:run),
      next_supervisor: next |> Keyword.fetch!(:under),
      daemon_pid: nil,
      daemon_restart_count: 0
    }
    |> tap(fn _ -> send(self(), :start) end)
  end

  @impl true
  def on_msg(
        :start,
        %{pg_dir: pg_dir, pg_port: pg_port, device: device, daemon_name: daemon_name} = state
      ) do
    # Verify PostgreSQL was initialized before attempting to start
    unless Postgres.initialized?(pg_dir: pg_dir) do
      log(
        "PostgreSQL data directory not initialized at #{pg_dir}/data - cannot start daemon",
        :error
      )

      {:stop, :not_initialized, state}
    else
      # Capture any PostgreSQL crash logs before cleanup
      capture_pg_crash_logs(pg_dir)

      # Use device from supervision tree for explicit run_dir management
      opts = if device, do: [device: device], else: []

      Postgres.cleanup_old_server(pg_dir, opts)

      daemon_spec = Postgres.daemon_spec(pg_dir: pg_dir, pg_port: pg_port, name: daemon_name)

      {:ok, pid} = start_daemon(daemon_spec)

      send(self(), :wait_for_ready)

      {:noreply, %{state | daemon_pid: pid}}
    end
  end

  # Handle daemon EXIT - restart if crashed (intercept before GracefulGenServer stops us)
  @impl GracefulGenServer
  def on_msg(
        {:EXIT, daemon_pid, reason},
        %{daemon_pid: daemon_pid, daemon_restart_count: restart_count, pg_dir: pg_dir} = state
      )
      when restart_count < 3 do
    log(
      "PostgreSQL daemon crashed with reason: #{inspect(reason)}, restarting (attempt #{restart_count + 1}/3)",
      :warning
    )

    # Capture crash logs before restart
    capture_pg_crash_logs(pg_dir)

    # Schedule restart after a brief delay
    Process.send_after(self(), :start, :timer.seconds(2))

    {:noreply, %{state | daemon_pid: nil, daemon_restart_count: restart_count + 1}}
  end

  def on_msg(
        {:EXIT, daemon_pid, reason},
        %{daemon_pid: daemon_pid, daemon_restart_count: restart_count} = state
      ) do
    log(
      "PostgreSQL daemon crashed with reason: #{inspect(reason)} after #{restart_count} restarts, giving up",
      :error
    )

    {:stop, {:daemon_crashed, reason}, state}
  end

  # Ignore EXIT from other linked processes (not our daemon)
  def on_msg({:EXIT, _other_pid, _reason}, state) do
    {:noreply, state}
  end

  @impl GracefulGenServer
  def on_msg(
        :wait_for_ready,
        %{
          pg_port: pg_port,
          task_supervisor: task_supervisor,
          next_specs: next_specs,
          next_supervisor: next_supervisor
        } = state
      ) do
    result =
      Task.Supervisor.async_nolink(task_supervisor, fn ->
        wait_for_postgres_ready(pg_port)
      end)
      |> Task.await(:timer.minutes(2))

    case result do
      :ok ->
        # Final health check before proceeding - verify PostgreSQL is actually accepting connections
        if Postgres.server_running?(pg_port: pg_port) do
          log("PostgreSQL daemon ready on port #{pg_port}, starting next stage", :info)
          Platform.start_next_stage(next_supervisor, next_specs)
          {:noreply, state}
        else
          log("PostgreSQL health check failed after wait - retrying in 10s", :warning)
          Process.send_after(self(), :wait_for_ready, :timer.seconds(10))
          {:noreply, state}
        end

      {:error, reason} ->
        log("PostgreSQL failed to become ready: #{inspect(reason)} - retrying in 10s", :warning)
        Process.send_after(self(), :wait_for_ready, :timer.seconds(10))
        {:noreply, state}
    end
  end

  @impl true
  def on_exit(reason, %{pg_port: pg_port, daemon_pid: daemon_pid}) do
    log("PostgreSQL daemon stage exiting: #{inspect(reason)}", :warning)

    if daemon_pid && Process.alive?(daemon_pid) do
      log("Stopping PostgreSQL daemon on port #{pg_port}", :info)
    end

    :ok
  end

  defp start_daemon({module, args}) do
    case apply(module, :start_link, args) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      error -> error
    end
  end

  defp wait_for_postgres_ready(pg_port, attempts \\ @max_startup_attempts) do
    cond do
      attempts <= 0 ->
        log("PostgreSQL failed to start after #{@max_startup_attempts} attempts", :error)
        {:error, :timeout}

      Postgres.server_running?(pg_port: pg_port) ->
        log("PostgreSQL responding on port #{pg_port}", :debug)
        :ok

      true ->
        log("Waiting for PostgreSQL on port #{pg_port} (#{attempts} attempts remaining)", :debug)
        Process.sleep(@startup_check_interval_ms)
        wait_for_postgres_ready(pg_port, attempts - 1)
    end
  end

  # Capture PostgreSQL crash logs for debugging
  defp capture_pg_crash_logs(pg_dir) do
    pg_data_dir = Path.join(pg_dir, "data")
    log_dir = Path.join(pg_data_dir, "log")

    # Check for PostgreSQL log files
    if File.dir?(log_dir) do
      case File.ls(log_dir) do
        {:ok, files} when files != [] ->
          files
          |> Enum.sort(:desc)
          |> Enum.take(1)
          |> Enum.each(fn file ->
            log_path = Path.join(log_dir, file)

            case File.read(log_path) do
              {:ok, content} ->
                # Get last 50 lines of log
                lines =
                  content
                  |> String.split("\n")
                  |> Enum.take(-50)
                  |> Enum.join("\n")

                log("PostgreSQL log (#{file}):\n#{lines}", :warning)

              {:error, reason} ->
                log("Could not read PostgreSQL log #{file}: #{inspect(reason)}", :debug)
            end
          end)

        _ ->
          :ok
      end
    end

    # Check for postmaster.pid to understand crash state
    postmaster_pid_file = Path.join(pg_data_dir, "postmaster.pid")

    if File.exists?(postmaster_pid_file) do
      case File.read(postmaster_pid_file) do
        {:ok, content} ->
          log("Stale postmaster.pid found:\n#{content}", :warning)

        _ ->
          :ok
      end
    end

    :ok
  end
end
