defmodule Platform.Storage.Pg.Initializer do
  @moduledoc """
  Step module for initializing PostgreSQL database.
  Runs once to set up the PostgreSQL data directory and configuration.
  """
  use GracefulGenServer, timeout: :timer.minutes(1)
  use Toolbox.OriginLog

  alias Platform.Tools.Postgres

  @max_retries 5
  @initial_retry_delay :timer.seconds(3)

  @impl true
  def on_init(opts) do
    next = opts |> Keyword.fetch!(:next)

    %{
      pg_dir: opts |> Keyword.fetch!(:pg_dir),
      pg_port: opts |> Keyword.fetch!(:pg_port),
      task_supervisor: opts |> Keyword.fetch!(:task_in),
      next_specs: next |> Keyword.fetch!(:run),
      next_supervisor: next |> Keyword.fetch!(:under),
      task_ref: nil,
      retries: 0,
      retry_delay: @initial_retry_delay
    }
    |> tap(fn _ -> send(self(), :start) end)
  end

  @impl true
  def on_msg(
        :start,
        %{
          pg_dir: pg_dir,
          pg_port: pg_port,
          task_supervisor: task_supervisor
        } = state
      ) do
    %{ref: ref} =
      Task.Supervisor.async_nolink(task_supervisor, fn ->
        try do
          Postgres.initialize(pg_dir: pg_dir, pg_port: pg_port)
        catch
          _, reason -> {:error, reason}
        end
      end)

    {:noreply, %{state | task_ref: ref}}
  end

  def on_msg({ref, :ok}, %{task_ref: ref} = state) do
    Process.demonitor(ref, [:flush])
    send(self(), :initialized)
    {:noreply, state}
  end

  def on_msg({ref, {:error, reason}}, %{task_ref: ref} = state) do
    Process.demonitor(ref, [:flush])
    log("PostgreSQL initialization failed: #{inspect(reason)}", :error)
    maybe_retry(state)
  end

  # Handle task crash (e.g., :epipe from initdb)
  def on_msg({:DOWN, ref, :process, _pid, reason}, %{task_ref: ref} = state) do
    log("PostgreSQL initialization task crashed: #{inspect(reason)}", :error)

    Postgres.ensure_run_dir(state.pg_dir)

    try do
      Postgres.cleanup_posix_shared_memory()
    catch
      _, _ -> :ok
    end

    maybe_retry(state)
  end

  def on_msg(:initialized, %{next_specs: next_specs, next_supervisor: next_supervisor} = state) do
    log("PostgreSQL initialized, starting next stage", :info)
    Platform.start_next_stage(next_supervisor, next_specs)
    {:noreply, state}
  end

  defp maybe_retry(%{retries: retries, retry_delay: delay} = state) do
    if retries >= @max_retries do
      log("PostgreSQL initialization failed after #{retries} retries, giving up", :error)
      {:stop, {:init_failed_after_retries, retries}, state}
    else
      log(
        "Retrying PostgreSQL initialization in #{delay}ms (attempt #{retries + 1}/#{@max_retries})",
        :warning
      )

      Process.send_after(self(), :start, delay)
      {:noreply, %{state | retries: retries + 1, retry_delay: min(delay * 2, :timer.minutes(1))}}
    end
  end

  @impl true
  def on_exit(_reason, _state), do: :ok
end
