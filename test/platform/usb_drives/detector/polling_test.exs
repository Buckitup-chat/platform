defmodule Platform.UsbDrives.Detector.PollingTest do
  use ExUnit.Case, async: true

  alias Platform.UsbDrives.Detector.Polling

  import Rewire

  @moduletag :capture_log

  doctest Polling

  test "module exists" do
    assert is_list(Polling.module_info())
  end

  defmodule PathStub do
    def wildcard(_), do: ~w(/dev/sda /dev/sda1 /dev/sdb /dev/sd1)
  end

  rewire(Polling, Path: PathStub)

  test "should parse current state well" do
    correct = MapSet.new(~w(sdb sda1))

    assert correct == Polling.current_device_set()
  end

  test "should compare to previous state correctly" do
    prev = MapSet.new(~w(sdb1 sda1))
    updated = MapSet.new(~w(sdb sda1))
    added = MapSet.new(~w(sdb))
    removed = MapSet.new(~w(sdb1))

    assert {updated, added, removed} == Polling.changes_against(prev)
  end
end
