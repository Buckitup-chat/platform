defmodule Platform.Tools.LsblkTest do
  use ExUnit.Case, async: true
  import Rewire
  alias Platform.Tools.Lsblk

  @moduletag :capture_log

  doctest Lsblk

  test "module exists" do
    assert is_list(Lsblk.module_info())
  end

  defmodule SystemMock do
    def cmd("lsblk", ["-o", "FSTYPE", "/dev/sda1"]) do
      {"""
      FSTYPE
      exfat
      """, 0}
    end
    def cmd("lsblk", ["-o", "FSTYPE", "/dev/mmcblk0p1"]) do
      {"""
      FSTYPE
      vfat
      """, 0}
    end
    def cmd("lsblk", ["-o", "FSTYPE", "/dev/mmcblk0p3"]) do
      {"""
       FSTYPE
       f2fs
       """, 0}
    end
    def cmd("lsblk", _) do
      {"not a block device", 32}
    end
  end

  rewire(Lsblk, System: SystemMock)

  test "should detect vfat" do
    assert "vfat" = Lsblk.fs_type("mmcblk0p1")
  end

  test "should detect exfat" do
    assert "vfat" = Lsblk.fs_type("mmcblk0p1")
  end

  test "should detect f2fs" do
    assert "vfat" = Lsblk.fs_type("mmcblk0p1")
  end

  test "should not detect fs type on no device" do
    assert :error = Lsblk.fs_type("no_device_xscdvfbrtgerfge")
  end
end
