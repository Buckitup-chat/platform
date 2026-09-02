defmodule Platform.Storage.Pg.DbCreator do
  @moduledoc """
  Step module for ensuring a PostgreSQL database exists.
  Runs once to create the specified database if it doesn't exist.

  The actual creation runs inside a supervised task guarded by a watchdog
  timeout. When the task crashes (e.g. :epipe from a dropped PG connection)
  or times out, the bounded retry loop advances instead of crashing the stage.
  """
  use GracefulGenServer, timeout: :timer.minutes(1)
  use Toolbox.OriginLog

  alias Platform.Leds
  alias Platform.Tools.Postgres

  @max_retries 5
  @initial_retry_delay :timer.seconds(3)
  @attempt_timeout :timer.seconds(90)

  @impl true
  def on_init(opts) do
    next = opts |> Keyword.fetch!(:next)

    %{
      db_name: opts |> Keyword.fetch!(:db_name),
      pg_port: opts |> Keyword.fetch!(:pg_port),
      task_supervisor: opts |> Keyword.fetch!(:task_in),
      next_specs: next |> Keyword.fetch!(:run),
      next_supervisor: next |> Keyword.fetch!(:under),
      task_ref: nil,
      task_pid: nil,
      watchdog_ref: nil,
      retries: 0,
      max_retries: opts |> Keyword.get(:max_retries, @max_retries),
      attempt_timeout: opts |> Keyword.get(:attempt_timeout, @attempt_timeout),
      retry_delay: opts |> Keyword.get(:initial_retry_delay, @initial_retry_delay)
    }
    |> tap(fn _ -> send(self(), :start) end)
  end

  @impl true
  def on_msg(
        :start,
        %{
          db_name: db_name,
          pg_port: pg_port,
          task_supervisor: task_supervisor,
          attempt_timeout: attempt_timeout
        } = state
      ) do
    %{ref: ref, pid: pid} =
      Task.Supervisor.async_nolink(task_supervisor, fn ->
        Postgres.ensure_db_exists(db_name, pg_port: pg_port)
      end)

    watchdog_ref = Process.send_after(self(), {:attempt_timeout, ref}, attempt_timeout)

    {:noreply, %{state | task_ref: ref, task_pid: pid, watchdog_ref: watchdog_ref}}
  end

  def on_msg({ref, {:ok, _name}}, %{task_ref: ref, db_name: db_name} = state) do
    Process.demonitor(ref, [:flush])
    log("Database '#{db_name}' ready, starting next stage", :info)
    send(self(), :db_ready)
    {:noreply, clear_attempt(state)}
  end

  def on_msg({ref, {:error, reason}}, %{task_ref: ref} = state) do
    Process.demonitor(ref, [:flush])
    log("Database creation failed: #{inspect(reason)}", :error)
    maybe_retry(clear_attempt(state))
  end

  def on_msg({:DOWN, ref, :process, _pid, reason}, %{task_ref: ref} = state) do
    log("Database creation task crashed: #{inspect(reason)}", :error)
    maybe_retry(clear_attempt(state))
  end

  def on_msg({:attempt_timeout, ref}, %{task_ref: ref, task_pid: pid} = state) do
    log("Database creation timed out after #{state.attempt_timeout}ms", :error)
    Process.demonitor(ref, [:flush])
    Process.exit(pid, :kill)
    maybe_retry(clear_attempt(state))
  end

  def on_msg(:db_ready, %{next_specs: next_specs, next_supervisor: next_supervisor} = state) do
    Platform.start_next_stage(next_supervisor, next_specs)
    {:noreply, state}
  end

  # Stale task/timer messages from a previous attempt.
  def on_msg(_msg, state), do: {:noreply, state}

  @impl true
  def on_exit(_reason, %{task_pid: task_pid}) do
    if task_pid, do: Process.exit(task_pid, :kill)
    :ok
  end

  def on_exit(_reason, _state), do: :ok

  defp clear_attempt(%{watchdog_ref: watchdog_ref} = state) do
    if watchdog_ref, do: Process.cancel_timer(watchdog_ref)
    %{state | task_ref: nil, task_pid: nil, watchdog_ref: nil}
  end

  defp maybe_retry(%{retries: retries, max_retries: max_retries, retry_delay: delay} = state) do
    if retries >= max_retries do
      log("Database creation failed after #{retries} retries, giving up", :error)
      escalate_failure()
      {:stop, {:db_creation_failed_after_retries, retries}, state}
    else
      log(
        "Retrying database creation in #{delay}ms (attempt #{retries + 1}/#{max_retries})",
        :warning
      )

      Process.send_after(self(), :start, delay)
      {:noreply, %{state | retries: retries + 1, retry_delay: min(delay * 2, :timer.minutes(1))}}
    end
  end

  defp escalate_failure do
    log("Database could not be created; downstream stages stay blocked.", :error)
    Leds.blink_alarm()
  end
end
