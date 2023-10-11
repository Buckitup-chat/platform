defmodule Platform.UsbDrives.Detector.WatcherTest do
  use ExUnit.Case, async: true

  alias Platform.UsbDrives.Detector.Polling
  alias Platform.UsbDrives.Detector.State
  alias Platform.UsbDrives.Detector.Watcher
  import Rewire

  @moduletag :capture_log
  doctest Watcher

  test "module exists" do
    assert is_list(Watcher.module_info())
  end

  test "genserver start" do
    {:ok, pid} = Watcher.start_link(name: Watcher.Test.Watcher)
    send(pid, {:DOWN, :some})

    assert Process.alive?(pid)

    GenServer.stop(pid)
  end

  defmodule PathStub do
    def wildcard(_), do: ~w(/dev/sda /dev/sda1 /dev/sdb /dev/sd1)
  end

  rewire(Polling, Path: PathStub, as: PollingMock)
  rewire(Watcher, Polling: PollingMock)

  test "new devices added" do
    fresh_state()
    |> fs_check_fires()
    |> assert_devices_timers_connected(~w[sda1 sdb], ~w[sda1 sdb], ~w[])
    |> add_connected_fires_for("sda1")
    |> assert_devices_timers_connected(~w[sda1 sdb], ~w[sdb], ~w[sda1])
  end

  test "device remove" do
    fresh_state()
    |> with_devices(~w[sda1 sdb sdc1])
    |> with_connected(~w[sda1 sdb sdc1])
    |> fs_check_fires()
    |> assert_devices_timers_connected(~w[sda1 sdb], ~w[], ~w[sda1 sdb])
  end

  test "device removed right after adding and timer worked before got canceled" do
    fresh_state()
    |> with_devices(~w[sda1 sdb sdc1])
    |> with_connecting(~w[sda1 sdb sdc1])
    |> fs_check_fires()
    |> assert_devices_timers_connected(~w[sda1 sdb], ~w[sda1 sdb], ~w[])
    |> add_connected_fires_for("sdc1")
    |> assert_devices_timers_connected(~w[sda1 sdb], ~w[sda1 sdb], ~w[])
  end

  defp fresh_state do
    State.new()
    |> State.put_timer(make_ref())
  end

  defp with_devices(state, device_list) do
    device_list
    |> MapSet.new()
    |> then(&State.put_devices(state, &1))
  end

  defp with_connecting(state, device_list) do
    device_list
    |> Enum.map(&{&1, make_ref()})
    |> Map.new()
    |> then(&State.add_connecting(state, &1))
  end

  defp with_connected(state, device_list) do
    device_list
    |> Enum.reduce(state, &State.add_connected(&2, &1))
  end

  defp fs_check_fires(state) do
    state
    |> then(&Watcher.handle_info(:check, &1))
    |> then(fn {:noreply, state} -> state end)
  end

  defp add_connected_fires_for(state, device) do
    state
    |> then(&Watcher.handle_info({:add_connected, device}, &1))
    |> then(fn {:noreply, state} -> state end)
  end

  defp assert_devices_timers_connected(state, devices, timers, connected) do
    assert is_reference(state.timer)
    assert state.devices === MapSet.new(devices)
    assert state.connecting_timers |> Map.keys() |> Enum.sort() == timers |> Enum.sort()
    assert state.connected_devices === MapSet.new(connected)

    state
  end
end
