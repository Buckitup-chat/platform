defmodule Platform.Storage.Pg.Initializer do
  @moduledoc """
  Step module for initializing PostgreSQL database.
  Runs once to set up the PostgreSQL data directory and configuration.

  The actual initialization runs inside a supervised task so that filesystem and
  shared-memory I/O can never block this process's message loop. Each attempt is
  guarded by a watchdog timeout: if the backing storage is wedged (e.g. a failing
  SD card stuck in a busy state), the attempt is abandoned and the bounded retry
  loop keeps advancing instead of stalling silently. When every retry is
  exhausted the failure is surfaced visibly (red LED + error log) before the step
  stops.
  """
  use GracefulGenServer, timeout: :timer.minutes(1)
  use Toolbox.OriginLog

  alias Platform.Leds
  alias Platform.Tools.Postgres

  @max_retries 5
  @initial_retry_delay :timer.seconds(3)
  # initdb finishes well within this on healthy storage; the ceiling exists only
  # to bound a wedged card that never returns.
  @attempt_timeout :timer.seconds(90)

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
          pg_dir: pg_dir,
          pg_port: pg_port,
          task_supervisor: task_supervisor,
          attempt_timeout: attempt_timeout
        } = state
      ) do
    # Normal failure returns {:error, _}; a crash (e.g. :epipe) arrives as {:DOWN}.
    %{ref: ref, pid: pid} =
      Task.Supervisor.async_nolink(task_supervisor, fn ->
        Postgres.initialize(pg_dir: pg_dir, pg_port: pg_port)
      end)

    watchdog_ref = Process.send_after(self(), {:attempt_timeout, ref}, attempt_timeout)

    {:noreply, %{state | task_ref: ref, task_pid: pid, watchdog_ref: watchdog_ref}}
  end

  def on_msg({ref, :ok}, %{task_ref: ref} = state) do
    Process.demonitor(ref, [:flush])
    send(self(), :initialized)
    {:noreply, clear_attempt(state)}
  end

  def on_msg({ref, {:error, reason}}, %{task_ref: ref} = state) do
    Process.demonitor(ref, [:flush])
    log("PostgreSQL initialization failed: #{inspect(reason)}", :error)
    maybe_retry(clear_attempt(state))
  end

  # Retry directly: the next Postgres.initialize/2 re-runs run-dir and shared-memory
  # cleanup itself, so we avoid the inline blocking I/O that previously wedged the loop.
  def on_msg({:DOWN, ref, :process, _pid, reason}, %{task_ref: ref} = state) do
    log("PostgreSQL initialization task crashed: #{inspect(reason)}", :error)
    maybe_retry(clear_attempt(state))
  end

  def on_msg({:attempt_timeout, ref}, %{task_ref: ref, task_pid: pid} = state) do
    log(
      "PostgreSQL initialization timed out after #{state.attempt_timeout}ms; storage may be failing",
      :error
    )

    Process.demonitor(ref, [:flush])
    Process.exit(pid, :kill)
    maybe_retry(clear_attempt(state))
  end

  def on_msg(:initialized, %{next_specs: next_specs, next_supervisor: next_supervisor} = state) do
    log("PostgreSQL initialized, starting next stage", :info)
    Platform.start_next_stage(next_supervisor, next_specs)
    {:noreply, state}
  end

  # Ignore stale task/timer messages — e.g. a watchdog firing in a race with task
  # completion, whose ref no longer matches the active attempt.
  def on_msg(_msg, state), do: {:noreply, state}

  defp clear_attempt(%{watchdog_ref: watchdog_ref} = state) do
    Process.cancel_timer(watchdog_ref)
    %{state | task_ref: nil, task_pid: nil, watchdog_ref: nil}
  end

  defp maybe_retry(%{retries: retries, max_retries: max_retries, retry_delay: delay} = state) do
    if retries >= max_retries do
      log("PostgreSQL initialization failed after #{retries} retries, giving up", :error)
      escalate_failure()
      {:stop, {:init_failed_after_retries, retries}, state}
    else
      log(
        "Retrying PostgreSQL initialization in #{delay}ms (attempt #{retries + 1}/#{max_retries})",
        :warning
      )

      Process.send_after(self(), :start, delay)
      {:noreply, %{state | retries: retries + 1, retry_delay: min(delay * 2, :timer.minutes(1))}}
    end
  end

  # Fast-flashing red LED is the only out-of-band signal that PostgreSQL/Electric
  # won't come up — most often a failing SD card.
  defp escalate_failure do
    log(
      "PostgreSQL could not be initialized; Electric/sync will not start. Check the SD card.",
      :error
    )

    Leds.blink_alarm()
  end

  @impl true
  def on_exit(_reason, _state), do: :ok
end
