defmodule Platform.Storage.Pg.Daemon do
  @moduledoc """
  PostgreSQL daemon supervision stage.
  Starts the PostgreSQL server daemon, waits for it to be ready,
  then starts the next stage.
  """
  use GracefulGenServer, timeout: :timer.minutes(3)
  use OriginLog

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
        %{pg_dir: pg_dir, pg_port: pg_port, daemon_name: daemon_name} = state
      ) do
    Postgres.cleanup_old_server(pg_dir)

    daemon_spec = Postgres.daemon_spec(pg_dir: pg_dir, pg_port: pg_port, name: daemon_name)

    [pg_dir, "data", "postmaster.pid"]
    |> Path.join()
    |> File.rm()

    {:ok, pid} = start_daemon(daemon_spec)

    send(self(), :wait_for_ready)

    {:noreply, %{state | daemon_pid: pid}}
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

  defp wait_for_postgres_ready(pg_port, attempts \\ 10) do
    cond do
      attempts <= 0 ->
        log("PostgreSQL failed to start after 10 attempts", :error)
        {:error, :timeout}

      Postgres.server_running?(pg_port: pg_port) ->
        log("PostgreSQL responding on port #{pg_port}", :debug)
        :ok

      true ->
        log("Waiting for PostgreSQL on port #{pg_port} (#{attempts} attempts remaining)", :debug)
        Process.sleep(2000)
        wait_for_postgres_ready(pg_port, attempts - 1)
    end
  end
end
