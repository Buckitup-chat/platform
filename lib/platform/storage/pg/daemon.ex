defmodule Platform.Storage.Pg.Daemon do
  @moduledoc """
  PostgreSQL daemon supervision stage.
  Starts the PostgreSQL server daemon, waits for it to be ready,
  then starts the next stage.

  Startup preparation — crash-log capture, stale-server cleanup, daemon spec
  building — runs inside a supervised task guarded by a watchdog. Every step of
  it shells out or touches storage, and running it inline used to let a single
  wedged command stall this message loop forever: the stage stayed "alive", so
  no supervisor ever restarted it, `Chat.Repo` never started, and every USB
  drive waiting on the internal DB was stuck before `Decider` could see it.

  The daemon itself is still started from this process, so it stays linked to
  the stage rather than to the task that prepared it.

  Waiting for the started server to answer is `Platform.Storage.Pg.Readiness`;
  this module owns the stage lifecycle, the attempt watchdog and the retries.
  """
  use GracefulGenServer, timeout: :timer.minutes(3)
  use Toolbox.OriginLog

  alias Platform.Leds
  alias Platform.Storage.Pg.Readiness
  alias Platform.Tools.Postgres
  alias Platform.Tools.Postgres.CrashLogs

  # Cap total readiness polling cycles (each ~70s: 60s poll + 10s wait)
  @max_ready_cycles 3
  # Preparation shells out to individually bounded commands (pg_ctl 45s, lsipc
  # and ipcs 15s each); the watchdog only has to catch what those bounds miss —
  # an unbounded `System.cmd` or a file read on wedged storage.
  @attempt_timeout :timer.minutes(2)
  @max_retries 2
  @initial_retry_delay :timer.seconds(3)
  @max_daemon_restarts 1

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
      daemon_restart_count: 0,
      ready_cycle_count: 0,
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

  # A daemon EXIT has to reach on_msg/2, where it earns a restart, instead of
  # stopping this stage the way GracefulGenServer treats every EXIT.
  defoverridable handle_info: 2

  @impl true
  def handle_info({:EXIT, _pid, _reason} = msg, state), do: on_msg(msg, state)
  def handle_info(msg, state), do: super(msg, state)

  @impl true
  def on_msg(
        :start,
        %{
          pg_dir: pg_dir,
          pg_port: pg_port,
          device: device,
          daemon_name: daemon_name,
          task_supervisor: task_supervisor,
          attempt_timeout: attempt_timeout
        } = state
      ) do
    %{ref: ref, pid: pid} =
      Task.Supervisor.async_nolink(task_supervisor, fn ->
        prepare_daemon_spec(pg_dir, pg_port, device, daemon_name)
      end)

    watchdog_ref = Process.send_after(self(), {:attempt_timeout, ref}, attempt_timeout)

    {:noreply, %{state | task_ref: ref, task_pid: pid, watchdog_ref: watchdog_ref}}
  end

  def on_msg({ref, {:ok, daemon_spec}}, %{task_ref: ref} = state) do
    Process.demonitor(ref, [:flush])

    case start_daemon(daemon_spec) do
      {:ok, pid} ->
        send(self(), :wait_for_ready)
        {:noreply, %{clear_attempt(state) | daemon_pid: pid}}

      error ->
        log("PostgreSQL daemon failed to start: #{inspect(error)}", :error)
        maybe_retry(clear_attempt(state))
    end
  end

  # The data directory is the initializer stage's job - retrying here would only
  # spin against a directory nothing in this stage can repair.
  def on_msg({ref, {:error, :not_initialized}}, %{task_ref: ref, pg_dir: pg_dir} = state) do
    Process.demonitor(ref, [:flush])

    log(
      "PostgreSQL data directory not initialized at #{pg_dir}/data - cannot start daemon",
      :error
    )

    {:stop, :not_initialized, clear_attempt(state)}
  end

  def on_msg({:DOWN, ref, :process, _pid, reason}, %{task_ref: ref} = state) do
    log("PostgreSQL startup preparation crashed: #{inspect(reason)}", :error)
    maybe_retry(clear_attempt(state))
  end

  def on_msg({:attempt_timeout, ref}, %{task_ref: ref, task_pid: pid} = state) do
    log(
      "PostgreSQL startup preparation timed out after #{state.attempt_timeout}ms; storage may be wedged",
      :error
    )

    Process.demonitor(ref, [:flush])
    Process.exit(pid, :kill)
    maybe_retry(clear_attempt(state))
  end

  # Our own daemon died: crash logs are captured by the next :start attempt.
  def on_msg(
        {:EXIT, daemon_pid, reason},
        %{daemon_pid: daemon_pid, daemon_restart_count: restarts} = state
      ) do
    if restarts < @max_daemon_restarts do
      log(
        "PostgreSQL daemon crashed with reason: #{inspect(reason)}, restarting (attempt #{restarts + 1}/#{@max_daemon_restarts})",
        :warning
      )

      Process.send_after(self(), :start, :timer.seconds(2))
      {:noreply, %{state | daemon_pid: nil, daemon_restart_count: restarts + 1}}
    else
      log(
        "PostgreSQL daemon crashed with reason: #{inspect(reason)} after #{restarts} restarts, giving up",
        :error
      )

      {:stop, {:daemon_crashed, reason}, state}
    end
  end

  # Anything else this stage is linked to dying is not fatal to it.
  def on_msg({:EXIT, _other_pid, _reason}, state), do: {:noreply, state}

  def on_msg(:wait_for_ready, %{ready_cycle_count: cycle} = state)
      when cycle >= @max_ready_cycles do
    log("PostgreSQL not ready after #{cycle} polling cycles, giving up", :error)
    {:stop, {:error, :pg_not_ready_after_timeout}, state}
  end

  def on_msg(
        :wait_for_ready,
        %{
          pg_port: pg_port,
          task_supervisor: task_supervisor,
          next_specs: next_specs,
          next_supervisor: next_supervisor,
          ready_cycle_count: cycle
        } = state
      ) do
    with :ok <- Readiness.await(task_supervisor, pg_port),
         true <- Postgres.server_running?(pg_port: pg_port) do
      log("PostgreSQL daemon ready on port #{pg_port}, starting next stage", :info)
      Platform.start_next_stage(next_supervisor, next_specs)
      {:noreply, state}
    else
      failure ->
        log(
          "PostgreSQL not ready (#{inspect(failure)}) - retrying in 10s (cycle #{cycle + 1}/#{@max_ready_cycles})",
          :warning
        )

        Process.send_after(self(), :wait_for_ready, :timer.seconds(10))
        {:noreply, %{state | ready_cycle_count: cycle + 1}}
    end
  end

  # Late replies from an attempt already reclaimed - e.g. a watchdog firing in a
  # race with task completion, whose ref no longer matches the active attempt.
  def on_msg({ref, _result}, state) when is_reference(ref), do: {:noreply, state}

  def on_msg({:DOWN, ref, :process, _pid, _reason}, state) when is_reference(ref),
    do: {:noreply, state}

  def on_msg({:attempt_timeout, _ref}, state), do: {:noreply, state}

  @impl true
  def on_exit(reason, %{pg_port: pg_port, daemon_pid: daemon_pid, task_pid: task_pid}) do
    log("PostgreSQL daemon stage exiting: #{inspect(reason)}", :warning)

    if daemon_pid, do: log("Stopping PostgreSQL daemon on port #{pg_port}", :info)

    # Killing the task closes its MuonTrap port, which takes the OS child with
    # it - a wedged pg_ctl must not outlive the stage that spawned it.
    if task_pid, do: Process.exit(task_pid, :kill)

    :ok
  end

  # Runs in the supervised task: everything here shells out or touches storage.
  defp prepare_daemon_spec(pg_dir, pg_port, device, daemon_name) do
    if Postgres.initialized?(pg_dir: pg_dir) do
      CrashLogs.capture(pg_dir)

      # Use device from supervision tree for explicit run_dir management
      device_opts = if device, do: [device: device], else: []
      Postgres.cleanup_old_server(pg_dir, device_opts)

      {:ok, Postgres.daemon_spec(pg_dir: pg_dir, pg_port: pg_port, name: daemon_name)}
    else
      {:error, :not_initialized}
    end
  end

  # MuonTrap.Daemon links to whoever calls start_link, so this belongs to the
  # stage process: started from the preparation task, PostgreSQL would die with it.
  defp start_daemon({module, args}) do
    case apply(module, :start_link, args) do
      {:error, {:already_started, pid}} -> {:ok, pid}
      result -> result
    end
  end

  defp clear_attempt(%{watchdog_ref: watchdog_ref} = state) do
    Process.cancel_timer(watchdog_ref)
    %{state | task_ref: nil, task_pid: nil, watchdog_ref: nil}
  end

  defp maybe_retry(%{retries: retries, max_retries: max_retries, retry_delay: delay} = state) do
    if retries >= max_retries do
      log("PostgreSQL daemon start failed after #{retries} retries, giving up", :error)
      escalate_failure()
      {:stop, {:start_failed_after_retries, retries}, state}
    else
      log(
        "Retrying PostgreSQL daemon start in #{delay}ms (attempt #{retries + 1}/#{max_retries})",
        :warning
      )

      Process.send_after(self(), :start, delay)
      {:noreply, %{state | retries: retries + 1, retry_delay: min(delay * 2, :timer.minutes(1))}}
    end
  end

  # Fast-flashing red LED is the only out-of-band signal that PostgreSQL won't
  # come up - without it the drive pipeline just goes quiet.
  defp escalate_failure do
    log(
      "PostgreSQL daemon could not be started; Electric/sync and USB drive detection stay blocked. Check the storage.",
      :error
    )

    Leds.blink_alarm()
  end
end
