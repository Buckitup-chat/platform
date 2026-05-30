defmodule Platform.Storage.Pg.InitializerTest do
  use ExUnit.Case, async: false

  import Rewire

  alias Platform.Storage.Pg.Initializer

  @moduletag :capture_log

  # Test doubles must precede `rewire`; they report to the test via :persistent_term.
  defmodule PostgresStub do
    def initialize(opts) do
      send(:persistent_term.get(:pg_initializer_probe), {:initialize_called, opts})
      :persistent_term.get(:pg_initializer_behavior).()
    end
  end

  defmodule LedsStub do
    def blink_alarm do
      send(:persistent_term.get(:pg_initializer_probe), :blink_alarm)
      :ok
    end
  end

  rewire(Initializer, Postgres: PostgresStub, Leds: LedsStub)

  setup do
    Process.flag(:trap_exit, true)
    :persistent_term.put(:pg_initializer_probe, self())

    {:ok, task_sup} = Task.Supervisor.start_link()
    {:ok, dyn_sup} = DynamicSupervisor.start_link(strategy: :one_for_one)

    on_exit(fn ->
      :persistent_term.erase(:pg_initializer_probe)
      :persistent_term.erase(:pg_initializer_behavior)
    end)

    %{task_sup: task_sup, dyn_sup: dyn_sup}
  end

  test "happy path: starts the next stage once PostgreSQL initializes", ctx do
    stub_initialize(fn -> :ok end)

    {:ok, _pid} = start_initializer(ctx, run: [notifying_next_stage(:next_stage_started)])

    assert_receive {:initialize_called, _opts}, 1_000
    assert_receive :next_stage_started, 1_000
    refute_received :blink_alarm
  end

  test "retries on init error and escalates after exhausting retries", ctx do
    stub_initialize(fn -> {:error, :boom} end)

    {:ok, pid} = start_initializer(ctx, max_retries: 1, initial_retry_delay: 10)

    # max_retries: 1 => initial attempt + 1 retry before giving up
    assert_receive {:initialize_called, _}, 1_000
    assert_receive {:initialize_called, _}, 1_000
    assert_receive :blink_alarm, 1_000
    assert_receive {:EXIT, ^pid, {:init_failed_after_retries, 1}}, 1_000
  end

  test "watchdog reclaims a wedged attempt so the retry loop keeps advancing", ctx do
    # initialize never returns; without the watchdog the loop would stall forever
    stub_initialize(fn -> Process.sleep(:infinity) end)

    {:ok, pid} =
      start_initializer(ctx, max_retries: 2, initial_retry_delay: 10, attempt_timeout: 40)

    # max_retries: 2 => 3 attempts, each reclaimed by the watchdog, then escalation
    assert_receive {:initialize_called, _}, 1_000
    assert_receive {:initialize_called, _}, 1_000
    assert_receive {:initialize_called, _}, 1_000
    assert_receive :blink_alarm, 1_000
    assert_receive {:EXIT, ^pid, {:init_failed_after_retries, 2}}, 1_000
  end

  # Helpers

  defp stub_initialize(behavior), do: :persistent_term.put(:pg_initializer_behavior, behavior)

  defp start_initializer(ctx, opts) do
    {run, opts} = Keyword.pop(opts, :run, [])

    [
      pg_dir: "/tmp/pg_initializer_test",
      pg_port: 5432,
      task_in: ctx.task_sup,
      next: [under: ctx.dyn_sup, run: run]
    ]
    |> Keyword.merge(opts)
    |> Initializer.start_link()
  end

  defp notifying_next_stage(message) do
    test = self()
    %{id: :next_stage, start: {Task, :start_link, [fn -> send(test, message) end]}}
  end
end
