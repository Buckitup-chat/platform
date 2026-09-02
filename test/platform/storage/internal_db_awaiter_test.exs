defmodule Platform.Storage.InternalDbAwaiterTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  import Rewire

  alias Platform.Storage.InternalDbAwaiter

  @moduletag :capture_log

  # Test doubles must precede `rewire`; they report to the test via :persistent_term.
  defmodule RepoStub do
    def query(_sql, _params) do
      if :persistent_term.get(:awaiter_pg_ready, false) do
        {:ok, %{rows: [[1]]}}
      else
        raise "could not lookup Ecto repo Chat.Repo because it was not started"
      end
    end
  end

  # Only the name matters - CubDB readiness is a `Process.whereis/1`.
  defmodule InternalDbStub do
  end

  defmodule LedsStub do
    def blink_alarm, do: send(:persistent_term.get(:awaiter_probe), :blink_alarm)
  end

  defmodule ChatBridgeStub do
    def notify(message), do: send(:persistent_term.get(:awaiter_probe), {:notified, message})
  end

  defmodule DbBrokersStub do
    def refresh, do: :ok
  end

  defmodule NetworkSynchronizationStub do
    def init_electric_peers, do: :ok
  end

  rewire(InternalDbAwaiter,
    ChatBridge: ChatBridgeStub,
    DbBrokers: DbBrokersStub,
    InternalDb: InternalDbStub,
    Leds: LedsStub,
    NetworkSynchronization: NetworkSynchronizationStub,
    Repo: RepoStub
  )

  setup do
    Process.flag(:trap_exit, true)
    :persistent_term.put(:awaiter_probe, self())
    :persistent_term.put(:awaiter_pg_ready, false)
    # CubDB up, PG down - the shape of the boot that lost main detection.
    Process.register(self(), InternalDbStub)

    {:ok, task_sup} = Task.Supervisor.start_link()
    {:ok, dyn_sup} = DynamicSupervisor.start_link(strategy: :one_for_one)

    on_exit(fn ->
      :persistent_term.erase(:awaiter_probe)
      :persistent_term.erase(:awaiter_pg_ready)
    end)

    %{task_sup: task_sup, dyn_sup: dyn_sup}
  end

  test "starts the next stage once both internal DBs answer", ctx do
    :persistent_term.put(:awaiter_pg_ready, true)

    {:ok, _pid} = start_awaiter(ctx, run: [notifying_next_stage(:next_stage_started)])

    assert_receive :next_stage_started, 1_000
    refute_received :blink_alarm
  end

  test "gives up, escalates and stops when the internal DB never comes up", ctx do
    {:ok, pid} = start_awaiter(ctx, max_attempts: 3, check_interval_ms: 5)

    assert_receive :blink_alarm, 1_000
    assert_receive {:notified, {:internal_db_unavailable, %{cubdb: true, pg: false}}}, 1_000
    # stopping hands the drive's rest_for_one chain a reason to restart the wait
    assert_receive {:EXIT, ^pid, :internal_db_unavailable}, 1_000
  end

  test "never starts the next stage while the internal DB is missing", ctx do
    {:ok, pid} =
      start_awaiter(ctx,
        max_attempts: 3,
        check_interval_ms: 5,
        run: [notifying_next_stage(:next_stage_started)]
      )

    assert_receive {:EXIT, ^pid, :internal_db_unavailable}, 1_000
    refute_received :next_stage_started
  end

  test "logs the wait every tenth attempt instead of every second", ctx do
    log =
      capture_log(fn ->
        {:ok, pid} = start_awaiter(ctx, max_attempts: 25, check_interval_ms: 1)

        assert_receive {:EXIT, ^pid, :internal_db_unavailable}, 2_000
      end)

    # attempts 1, 10 and 20 - not one line per attempt
    assert occurrences(log, "Waiting for internal DBs") == 3
    assert occurrences(log, "Chat.Repo PG not ready") == 3
  end

  # Helpers

  defp start_awaiter(ctx, opts) do
    {run, opts} = Keyword.pop(opts, :run, [])

    [task_in: ctx.task_sup, next: [under: ctx.dyn_sup, run: run]]
    |> Keyword.merge(opts)
    |> InternalDbAwaiter.start_link()
  end

  defp notifying_next_stage(message) do
    test = self()
    %{id: :next_stage, start: {Task, :start_link, [fn -> send(test, message) end]}}
  end

  defp occurrences(log, text), do: log |> String.split(text) |> length() |> Kernel.-(1)
end
