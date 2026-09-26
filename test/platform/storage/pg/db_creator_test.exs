defmodule Platform.Storage.Pg.DbCreatorTest do
  use ExUnit.Case, async: false

  import Rewire

  alias Platform.Storage.Pg.DbCreator

  @moduletag :capture_log

  defmodule PostgresStub do
    def ensure_db_exists(db_name, opts) do
      send(:persistent_term.get(:db_creator_probe), {:ensure_db_exists_called, db_name, opts})
      :persistent_term.get(:db_creator_behavior).()
    end
  end

  defmodule LedsStub do
    def blink_alarm do
      send(:persistent_term.get(:db_creator_probe), :blink_alarm)
      :ok
    end
  end

  rewire(DbCreator, Postgres: PostgresStub, Leds: LedsStub)

  setup do
    Process.flag(:trap_exit, true)
    :persistent_term.put(:db_creator_probe, self())

    {:ok, task_sup} = Task.Supervisor.start_link()
    {:ok, dyn_sup} = DynamicSupervisor.start_link(strategy: :one_for_one)

    on_exit(fn ->
      :persistent_term.erase(:db_creator_probe)
      :persistent_term.erase(:db_creator_behavior)
    end)

    %{task_sup: task_sup, dyn_sup: dyn_sup}
  end

  test "happy path: starts the next stage once database is created", ctx do
    stub_ensure_db(fn -> {:ok, "test_db"} end)

    {:ok, _pid} = start_db_creator(ctx, run: [notifying_next_stage(:next_stage_started)])

    assert_receive {:ensure_db_exists_called, "test_db", _opts}, 1_000
    assert_receive :next_stage_started, 1_000
    refute_received :blink_alarm
  end

  test "retries on error result and escalates after exhausting retries", ctx do
    stub_ensure_db(fn -> {:error, :connection_refused} end)

    {:ok, pid} = start_db_creator(ctx, max_retries: 1, initial_retry_delay: 10)

    assert_receive {:ensure_db_exists_called, _, _}, 1_000
    assert_receive {:ensure_db_exists_called, _, _}, 1_000
    assert_receive :blink_alarm, 1_000
    assert_receive {:EXIT, ^pid, {:db_creation_failed_after_retries, 1}}, 1_000
  end

  test "retries on task crash (e.g. :epipe) and eventually succeeds", ctx do
    call_count = :counters.new(1, [:atomics])

    stub_ensure_db(fn ->
      :counters.add(call_count, 1, 1)

      case :counters.get(call_count, 1) do
        1 -> exit(:epipe)
        _ -> {:ok, "test_db"}
      end
    end)

    {:ok, _pid} =
      start_db_creator(ctx,
        run: [notifying_next_stage(:next_stage_started)],
        initial_retry_delay: 10
      )

    assert_receive {:ensure_db_exists_called, _, _}, 1_000
    assert_receive {:ensure_db_exists_called, _, _}, 1_000
    assert_receive :next_stage_started, 1_000
    refute_received :blink_alarm
  end

  test "watchdog reclaims a wedged attempt so the retry loop keeps advancing", ctx do
    stub_ensure_db(fn -> Process.sleep(:infinity) end)

    {:ok, pid} =
      start_db_creator(ctx, max_retries: 2, initial_retry_delay: 10, attempt_timeout: 40)

    assert_receive {:ensure_db_exists_called, _, _}, 1_000
    assert_receive {:ensure_db_exists_called, _, _}, 1_000
    assert_receive {:ensure_db_exists_called, _, _}, 1_000
    assert_receive :blink_alarm, 1_000
    assert_receive {:EXIT, ^pid, {:db_creation_failed_after_retries, 2}}, 1_000
  end

  # Helpers

  defp stub_ensure_db(behavior), do: :persistent_term.put(:db_creator_behavior, behavior)

  defp start_db_creator(ctx, opts) do
    {run, opts} = Keyword.pop(opts, :run, [])

    [
      db_name: "test_db",
      pg_port: 5432,
      task_in: ctx.task_sup,
      next: [under: ctx.dyn_sup, run: run]
    ]
    |> Keyword.merge(opts)
    |> DbCreator.start_link()
  end

  defp notifying_next_stage(message) do
    test = self()
    %{id: :next_stage, start: {Task, :start_link, [fn -> send(test, message) end]}}
  end
end
