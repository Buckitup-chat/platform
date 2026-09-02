defmodule Platform.Storage.BootWatchdogTest do
  use ExUnit.Case, async: false

  import Rewire

  alias Platform.Storage.BootWatchdog

  @moduletag :capture_log

  defmodule LedsStub do
    def blink_alarm, do: send(:persistent_term.get(:boot_watchdog_probe), :blink_alarm)
  end

  defmodule Stage do
    @moduledoc """
    Stands in for a boot stage: alive, idle, and never finishing on its own -
    exactly what no supervisor above it can notice.
    """
    use GenServer

    def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok)

    @impl true
    def init(_args), do: {:ok, :ok}
  end

  rewire(BootWatchdog, Leds: LedsStub)

  setup do
    :persistent_term.put(:boot_watchdog_probe, self())
    on_exit(fn -> :persistent_term.erase(:boot_watchdog_probe) end)

    :ok
  end

  test "kills the deepest stage of a tree that stopped advancing" do
    %{root: root, deep: deep, shallow: shallow} = start_tree()
    deep_ref = Process.monitor(deep)

    start_watchdog(root)

    assert_receive {:DOWN, ^deep_ref, :process, ^deep, :killed}, 1_000
    # earlier stages already did their job - only the stuck one is restarted
    assert Process.alive?(shallow)
  end

  test "leaves a tree alone once it reached its terminal child" do
    %{root: root, deep: deep} = start_tree(terminal?: true)
    deep_ref = Process.monitor(deep)

    start_watchdog(root)

    refute_receive {:DOWN, ^deep_ref, :process, _pid, _reason}, 300
    refute_received :blink_alarm
  end

  test "stops killing and raises the alarm when restarts change nothing" do
    %{root: root} = start_tree()

    start_watchdog(root)

    # three fruitless kills, then it gives up on that tree
    assert_receive :blink_alarm, 2_000
  end

  # Helpers

  # Mimics a staged tree mid-boot: a finished stage at the root, the stage in
  # progress nested one level deeper.
  defp start_tree(opts \\ []) do
    inner_children =
      [%{id: :deep_stage, start: {Stage, :start_link, [[]]}}] ++
        terminal_child(Keyword.get(opts, :terminal?, false))

    {:ok, root} =
      Supervisor.start_link(
        [
          %{id: :shallow_stage, start: {Stage, :start_link, [[]]}},
          %{
            id: :inner,
            type: :supervisor,
            start: {Supervisor, :start_link, [inner_children, [strategy: :one_for_one]]}
          }
        ],
        strategy: :one_for_one,
        max_restarts: 10,
        max_seconds: 1
      )

    inner = child_pid(root, :inner)

    %{root: root, deep: child_pid(inner, :deep_stage), shallow: child_pid(root, :shallow_stage)}
  end

  defp terminal_child(false), do: []
  defp terminal_child(true), do: [%{id: :terminal, start: {Stage, :start_link, [[]]}}]

  defp start_watchdog(root) do
    group = %{name: :test, roots: fn -> [root] end, terminal: :terminal, stall_ms: 20}

    BootWatchdog.start_link(name: nil, groups: [group], interval_ms: 10)
  end

  defp child_pid(supervisor, id) do
    supervisor
    |> Supervisor.which_children()
    |> Enum.find_value(fn {child_id, pid, _type, _modules} -> child_id == id && pid end)
  end
end
