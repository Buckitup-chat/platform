defmodule Platform.UsbDrives.Detector.StateTest do
  use ExUnit.Case, async: true

  alias Platform.UsbDrives.Detector.State

  @moduletag :capture_log

  doctest State

  test "module exists" do
    assert is_list(State.module_info())
  end

  test "new returns a new state with default values" do
    state = State.new()

    assert state.devices == MapSet.new()
    assert state.timer == nil
    assert state.connected_devices == MapSet.new()
    assert state.connecting_timers == %{}
  end

  test "put_timer updates the timer value in the state" do
    state = State.new()
    ref = make_ref()
    new_state = State.put_timer(state, ref)

    assert new_state.timer == ref
  end

  test "positive flow should work" do
    State.new()
    |> State.add_connecting(%{"sda1" => make_ref()})
    |> State.put_devices(MapSet.new(["sda1"]))
    |> tap(fn state ->
      assert State.has_connecting?(state, "sda1")
      assert State.has_device?(state, "sda1")
      refute State.has_connected?(state, "sda1")
    end)
    |> tap(fn state ->
      assert is_reference(State.connecting_timer(state, "sda1"))
    end)
    |> State.discard_connecting(["sda1"])
    |> State.add_connected("sda1")
    |> tap(fn state ->
      refute State.has_connecting?(state, "sda1")
      assert State.has_device?(state, "sda1")
      assert State.has_connected?(state, "sda1")
    end)
    |> State.put_devices(MapSet.new())
    |> State.delete_device("sda1")
    |> tap(fn state ->
      refute State.has_connecting?(state, "sda1")
      refute State.has_device?(state, "sda1")
      refute State.has_connected?(state, "sda1")
    end)
  end
end
