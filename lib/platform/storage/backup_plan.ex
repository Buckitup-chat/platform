defmodule Platform.Storage.BackupPlan do
  @moduledoc """
  Backup drive scenario as link plans, run by `Chat.Storage.PlanRunner`.

  Backup follows the Default unit: internal tends to overflow, so a backup fed from
  it while main is attached would silently miss data.

  - one-shot: `:backup_once` against the Default at start, then ejects the drive
  - continuous: `:backup_continuous`, then `default ~> backup` keeps replicating

  On `{:default_switched, new}` a running plan restarts against the new Default; a
  finished continuous plan re-homes with `:backup_rehome`. Stopping a runner stops
  its links, so no slot stays on the old Default.

  Options: `device:` (required), `continuous?:` (required).

  See `chat/docs/pq/reqs/files/pq_storage_units.proposed.md` §2.7.3.
  """

  use GracefulGenServer
  use Toolbox.OriginLog

  import Chat.Storage.Link, only: [~>: 2]

  alias Chat.Db.Common
  alias Chat.Ordering
  alias Chat.Storage.Default
  alias Chat.Storage.PlanRunner
  alias Chat.Storage.Unit
  alias Chat.Storage.Units
  alias Chat.Sync.DbBrokers
  alias Platform.Leds
  alias Platform.Storage.Stopper

  @check_ms 500

  @spec plan(:backup_once | :backup_continuous, Unit.t(), Unit.t()) :: [PlanRunner.step()]
  def plan(:backup_once, default, backup) do
    [
      # restore: rows + blobs only the drive has
      {:bootstrap, backup ~> default},
      {:bootstrap, default ~> backup},
      {:await, [backup ~> default, default ~> backup], :chunks},
      :eject
    ]
  end

  def plan(:backup_continuous, default, backup),
    do: (plan(:backup_once, default, backup) -- [:eject]) ++ [{:replicate, default ~> backup}]

  @spec plan(:backup_rehome, Unit.t(), Unit.t(), Unit.t()) :: [PlanRunner.step()]
  def plan(:backup_rehome, old, new, backup) do
    [
      {:stop, old ~> backup},
      # a diff only: the drive already holds most of it
      {:bootstrap, new ~> backup},
      {:replicate, new ~> backup}
    ]
  end

  @impl GracefulGenServer
  def on_init(opts) do
    Phoenix.PubSub.subscribe(Chat.PubSub, "storage")

    state = %{
      device: Keyword.fetch!(opts, :device),
      name: if(Keyword.fetch!(opts, :continuous?), do: :backup_continuous, else: :backup_once),
      backup: registered(:backup, Unit.usb(Keyword.fetch!(opts, :device), :backup)),
      default: current_default(),
      runner: nil,
      done?: false
    }

    set_backup_flag(true)
    Leds.blink_read()
    schedule_check()

    %{state | runner: start_plan(state, plan(state.name, state.default, state.backup))}
  end

  @impl GracefulGenServer
  def on_msg(:check, %{runner: nil} = state), do: {:noreply, state}

  def on_msg(:check, %{runner: runner} = state) do
    case PlanRunner.info(runner) do
      %{status: :running} ->
        schedule_check()
        {:noreply, state}

      %{status: status} ->
        log("#{state.name} #{inspect(status)}", if(status == :done, do: :info, else: :error))
        synced()
        {:noreply, %{state | done?: true}}
    end
  end

  def on_msg({:default_switched, %Unit{id: id}}, %{default: %Unit{id: id}} = state),
    do: {:noreply, state}

  def on_msg({:default_switched, new}, state), do: {:noreply, rehome(state, new)}

  def on_msg(_msg, state), do: {:noreply, state}

  @impl GracefulGenServer
  def on_exit(reason, %{runner: runner}) do
    log("exit #{inspect(reason)}", :info)
    stop(runner)
    synced()
  end

  defp rehome(%{default: old, backup: backup} = state, new) do
    new = registered(new.role, new)
    log("Default switched #{inspect(old.id)} -> #{inspect(new.id)}", :info)
    stop(state.runner)

    runner =
      case {state.name, state.done?} do
        # the one-shot plan is ejecting the drive already
        {:backup_once, true} -> nil
        {:backup_continuous, true} -> start_plan(state, plan(:backup_rehome, old, new, backup))
        {name, false} -> start_plan(state, plan(name, new, backup))
      end

    # a running plan's check loop is still scheduled
    if runner && state.done? do
      set_backup_flag(true)
      schedule_check()
    end

    %{state | default: new, runner: runner, done?: is_nil(runner)}
  end

  defp start_plan(%{device: device}, steps) do
    {:ok, runner} = PlanRunner.start_link(plan: steps, eject: fn -> eject(device) end)
    runner
  end

  defp eject(device) do
    {:ok, _} = Stopper.start_link(wait: 100, device: device)
    :ok
  end

  defp synced do
    set_backup_flag(false)
    Ordering.reset()
    DbBrokers.refresh()
    Leds.blink_done()
  end

  # The registered unit carries the PG system id the links stamp on missing_chunks
  defp current_default do
    default = Default.unit()
    registered(default.role, default)
  end

  defp registered(role, fallback) do
    case Units.by_role(role) do
      {:ok, unit} -> unit
      :error -> fallback
    end
  end

  defp set_backup_flag(value) do
    Common.get_chat_db_env(:flags)
    |> Keyword.put(:backup, value)
    |> then(&Common.put_chat_db_env(:flags, &1))
  end

  defp stop(nil), do: :ok
  defp stop(runner), do: if(Process.alive?(runner), do: GenServer.stop(runner))

  defp schedule_check, do: Process.send_after(self(), :check, @check_ms)
end
