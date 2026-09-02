defmodule Platform.Storage.InternalDbAwaiter do
  @moduledoc """
  Waits for the internal databases (CubDB and PostgreSQL) before the rest of a
  drive's boot chain starts.

  The wait is bounded. The internal DB stage can end up alive but never
  finishing, and polling here forever turned that into a drive that mounts,
  lights up and is then silently ignored: the chain never reached `Decider`, so
  nothing was recognised as main until someone rebooted the device. Giving up
  escalates - error log, alarm LED, a notification to Chat - and stops this
  step, so the drive's `rest_for_one` chain restarts the wait instead of
  hanging on it, and picks the drive up as soon as the internal DB recovers.
  """
  use GracefulGenServer
  use Toolbox.OriginLog

  alias Chat.Db.InternalDb
  alias Chat.NetworkSynchronization
  alias Chat.Repo
  alias Chat.Sync.DbBrokers
  alias Platform.ChatBridge
  alias Platform.Leds

  @check_interval_ms 1_000
  # The internal DB answers within seconds on healthy storage; the ceiling only
  # bounds a stage that is never going to finish.
  @max_attempts 90
  # Polling once a second per drive drowns the device log - the failing boot log
  # QA captured was 90% this one message.
  @log_every 10

  @impl true
  def on_init(opts) do
    next_opts = opts |> Keyword.fetch!(:next)

    %{
      task_in: opts |> Keyword.fetch!(:task_in),
      next: {next_opts |> Keyword.fetch!(:run), next_opts |> Keyword.fetch!(:under)},
      attempt: 1,
      max_attempts: opts |> Keyword.get(:max_attempts, @max_attempts),
      check_interval_ms: opts |> Keyword.get(:check_interval_ms, @check_interval_ms)
    }
    |> tap(fn _ -> send(self(), :check) end)
  end

  @impl true
  def on_msg(:check, %{attempt: attempt, max_attempts: max_attempts} = state)
      when attempt > max_attempts,
      do: give_up(state)

  def on_msg(:check, %{attempt: attempt} = state) do
    loud? = loud?(attempt)

    case readiness(loud?) do
      %{cubdb: true, pg: true} ->
        log("Internal DBs ready", :info)
        send(self(), :ready)

      readiness ->
        keep_waiting(state, readiness, loud?)
    end

    {:noreply, %{state | attempt: attempt + 1}}
  end

  def on_msg(:ready, %{next: {next_specs, next_supervisor}} = state) do
    DbBrokers.refresh()
    NetworkSynchronization.init_electric_peers()
    Platform.start_next_stage(next_supervisor, next_specs)

    {:noreply, state}
  end

  @impl true
  def on_exit(_reason, _state), do: :ok

  defp keep_waiting(
         %{attempt: attempt, max_attempts: max_attempts, check_interval_ms: interval},
         readiness,
         loud?
       ) do
    if loud? do
      log(
        "Waiting for internal DBs (attempt #{attempt}/#{max_attempts}, #{describe_readiness(readiness)})",
        :info
      )
    end

    Process.send_after(self(), :check, interval)
  end

  # Silent here is worse than noisy: the drive is mounted and its LED is on, so
  # nothing else tells the operator why it is being ignored.
  defp give_up(%{attempt: attempt} = state) do
    readiness = readiness(false)

    log(
      "Internal DBs never became ready after #{attempt - 1} attempts " <>
        "(#{describe_readiness(readiness)}) - this drive cannot boot",
      :error
    )

    Leds.blink_alarm()
    ChatBridge.notify({:internal_db_unavailable, readiness})

    {:stop, :internal_db_unavailable, state}
  end

  defp readiness(loud?), do: %{cubdb: cubdb_ready?(), pg: pg_ready?(loud?)}

  defp describe_readiness(%{cubdb: cubdb?, pg: pg?}), do: "CubDB=#{cubdb?}, PG=#{pg?}"

  defp loud?(attempt), do: attempt == 1 or rem(attempt, @log_every) == 0

  defp cubdb_ready?, do: Process.whereis(InternalDb) != nil

  defp pg_ready?(loud?) do
    Repo.query("SELECT 1", [])
    true
  rescue
    error -> not_ready(loud?, "Chat.Repo PG not ready: #{inspect(error)}")
  catch
    :exit, reason ->
      not_ready(loud?, "Chat.Repo PG exited during readiness check: #{inspect(reason)}")
  end

  defp not_ready(loud?, message) do
    if loud?, do: log(message, :warning)

    false
  end
end
