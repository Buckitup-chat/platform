defmodule Platform.Storage.Pg.DaemonTest do
  use ExUnit.Case, async: false

  import Rewire

  alias Platform.Storage.Pg.Daemon

  @moduletag :capture_log

  @pg_dir "/tmp/pg_daemon_test"
  @device "sda1"

  # Test doubles must precede `rewire`; they report to the test via :persistent_term.
  defmodule PostgresStub do
    def initialized?(opts) do
      send(probe(), {:initialized_called, opts})
      stubbed_result(:initialized?, fn -> true end)
    end

    def cleanup_old_server(pg_dir, opts) do
      send(probe(), {:cleanup_called, pg_dir, opts})
      stubbed_result(:cleanup_old_server, fn -> :ok end)
    end

    def daemon_spec(opts) do
      send(probe(), {:daemon_spec_called, opts})
      {Agent, [fn -> :ok end]}
    end

    def server_running?(_opts), do: true

    defp probe, do: :persistent_term.get(:pg_daemon_probe)

    defp stubbed_result(function, default) do
      :persistent_term.get(:pg_daemon_behavior, %{})
      |> Map.get(function, default)
      |> apply([])
    end
  end

  defmodule CrashLogsStub do
    def capture(_pg_dir), do: :ok
  end

  defmodule LedsStub do
    def blink_alarm do
      send(:persistent_term.get(:pg_daemon_probe), :blink_alarm)
      :ok
    end
  end

  # Rewiring is not transitive: without its own stubbed Postgres the readiness
  # poller would shell out to the real psql for a full 60s of polling.
  rewire(Platform.Storage.Pg.Readiness, Postgres: PostgresStub, as: StubbedReadiness)

  rewire(Daemon,
    Postgres: PostgresStub,
    CrashLogs: CrashLogsStub,
    Leds: LedsStub,
    Readiness: StubbedReadiness
  )

  setup do
    Process.flag(:trap_exit, true)
    :persistent_term.put(:pg_daemon_probe, self())

    {:ok, task_sup} = Task.Supervisor.start_link()
    {:ok, dyn_sup} = DynamicSupervisor.start_link(strategy: :one_for_one)

    on_exit(fn ->
      :persistent_term.erase(:pg_daemon_probe)
      :persistent_term.erase(:pg_daemon_behavior)
    end)

    %{task_sup: task_sup, dyn_sup: dyn_sup}
  end

  test "happy path: prepares, starts the daemon and then the next stage", ctx do
    {:ok, _pid} = start_daemon_stage(ctx, run: [notifying_next_stage(:next_stage_started)])

    assert_receive {:initialized_called, pg_dir: @pg_dir}, 1_000
    assert_receive {:cleanup_called, @pg_dir, [device: @device]}, 1_000
    assert_receive {:daemon_spec_called, _opts}, 1_000
    assert_receive :next_stage_started, 1_000
    refute_received :blink_alarm
  end

  test "stops without retrying when the data directory is not initialized", ctx do
    stub_postgres(initialized?: fn -> false end)

    {:ok, pid} = start_daemon_stage(ctx, initial_retry_delay: 10)

    assert_receive {:initialized_called, _}, 1_000
    assert_receive {:EXIT, ^pid, :not_initialized}, 1_000
    refute_received {:cleanup_called, _, _}
  end

  test "watchdog reclaims a wedged preparation and keeps the loop responsive", ctx do
    # cleanup never returns; running it inline used to wedge the stage forever
    stub_postgres(cleanup_old_server: fn -> Process.sleep(:infinity) end)

    {:ok, pid} =
      start_daemon_stage(ctx, max_retries: 2, initial_retry_delay: 10, attempt_timeout: 100)

    assert_receive {:cleanup_called, _, _}, 1_000

    # the message loop still answers while the preparation task hangs
    assert %{task_ref: ref} = :sys.get_state(pid)
    assert is_reference(ref)

    # max_retries: 2 => 3 attempts, each reclaimed by the watchdog, then escalation
    assert_receive {:cleanup_called, _, _}, 1_000
    assert_receive {:cleanup_called, _, _}, 1_000
    assert_receive :blink_alarm, 1_000
    assert_receive {:EXIT, ^pid, {:start_failed_after_retries, 2}}, 1_000
  end

  test "retries when the preparation task crashes", ctx do
    stub_postgres(initialized?: fn -> raise "storage gone" end)

    {:ok, pid} = start_daemon_stage(ctx, max_retries: 1, initial_retry_delay: 10)

    # max_retries: 1 => initial attempt + 1 retry before giving up
    assert_receive {:initialized_called, _}, 1_000
    assert_receive {:initialized_called, _}, 1_000
    assert_receive :blink_alarm, 1_000
    assert_receive {:EXIT, ^pid, {:start_failed_after_retries, 1}}, 1_000
  end

  # Helpers

  defp stub_postgres(behaviors), do: :persistent_term.put(:pg_daemon_behavior, Map.new(behaviors))

  defp start_daemon_stage(ctx, opts) do
    {run, opts} = Keyword.pop(opts, :run, [])

    [
      pg_dir: @pg_dir,
      pg_port: 5433,
      device: @device,
      name: :pg_daemon_test,
      task_in: ctx.task_sup,
      next: [under: ctx.dyn_sup, run: run]
    ]
    |> Keyword.merge(opts)
    |> Daemon.start_link()
  end

  defp notifying_next_stage(message) do
    test = self()
    %{id: :next_stage, start: {Task, :start_link, [fn -> send(test, message) end]}}
  end
end
