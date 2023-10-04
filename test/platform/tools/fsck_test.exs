defmodule Platform.Tools.FsckTest do
  use ExUnit.Case, async: true

  import Rewire

  alias Platform.Tools.Fsck

  @moduletag :capture_log
  doctest Fsck

  test "module exists" do
    assert is_list(Fsck.module_info())
  end

  defmodule SystemMock do
    def cmd("fsck.exfat", ["-y", "/dev/sda1"]), do: {"", 0}
    def cmd("fsck.vfat", ["-y", "/dev/mmcblk0p1"]), do: {"intentional error", 255}
    def cmd("fsck.f2fs", ["-y", "-a", "/dev/mmcblk0p3"]), do: {"all good", 0}
  end

  rewire(Fsck, System: SystemMock)

  test "exfat" do
    assert Fsck.exfat("sda1")
  end

  test "vfat" do
    refute Fsck.vfat("mmcblk0p1")
  end

  test "f2fs" do
    assert Fsck.f2fs("mmcblk0p3")
  end
end
