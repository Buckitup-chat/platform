defmodule Platform.Storage.Pg.Daemon do
  @moduledoc """
  PostgreSQL daemon supervision stage.
  Starts the PostgreSQL server daemon, waits for it to be ready,
  then starts the next stage.
  """
  use GracefulGenServer, timeout: :timer.minutes(3)

  require Logger

  alias Platform.Tools.Postgres

  @impl true
  def on_init(opts) do
    next = opts |> Keyword.fetch!(:next)

    %{
      pg_dir: opts |> Keyword.fetch!(:pg_dir),
      pg_port: opts |> Keyword.fetch!(:pg_port),
      daemon_name: Keyword.get(opts, :name, :postgres_daemon),
      task_supervisor: opts |> Keyword.fetch!(:task_in),
      next_specs: next |> Keyword.fetch!(:run),
      next_supervisor: next |> Keyword.fetch!(:under),
      daemon_pid: nil
    }
    |> tap(fn _ -> send(self(), :start) end)
  end

  @impl true
  def on_msg(
        :start,
        %{
          pg_dir: pg_dir,
          pg_port: pg_port,
          daemon_name: daemon_name,
          task_supervisor: task_supervisor,
          next_specs: next_specs,
          next_supervisor: next_supervisor
        } = state
      ) do
    # Start the postgres daemon as a child process
    daemon_spec = Postgres.daemon_spec(pg_dir: pg_dir, pg_port: pg_port, name: daemon_name)

    [pg_dir, "data", "postmaster.pid"]
    |> Path.join()
    |> File.rm()

    {:ok, pid} = start_daemon(daemon_spec)

    # Wait for PostgreSQL to be ready
    Task.Supervisor.async_nolink(task_supervisor, fn ->
      wait_for_postgres_ready(pg_port)
    end)
    |> Task.await(:timer.minutes(2))

    Logger.info("PostgreSQL daemon ready on port #{pg_port}, starting next stage")
    Platform.start_next_stage(next_supervisor, next_specs)

    {:noreply, %{state | daemon_pid: pid}}
  end

  @impl true
  def on_exit(reason, %{pg_port: pg_port, daemon_pid: daemon_pid}) do
    Logger.warning("PostgreSQL daemon stage exiting: #{inspect(reason)}")

    # The MuonTrap.Daemon will be stopped by the supervisor
    if daemon_pid && Process.alive?(daemon_pid) do
      Logger.info("Stopping PostgreSQL daemon on port #{pg_port}")
    end

    :ok
  end

  defp start_daemon({module, args}) do
    # Start the daemon as a supervised child
    case apply(module, :start_link, args) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      error -> error
    end
  end

  defp wait_for_postgres_ready(pg_port, attempts \\ 10) do
    if Postgres.server_running?(pg_port: pg_port) do
      :ok
    else
      if attempts > 0 do
        Process.sleep(2000)
        wait_for_postgres_ready(pg_port, attempts - 1)
      else
        Logger.error("PostgreSQL failed to start after 10 attempts")
        {:error, :timeout}
      end
    end
  end
end
