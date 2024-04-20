defmodule Platform.Tools.Mkfs do
  @moduledoc "mkfs wrapper"

  # def exfat(device), do: System.cmd("mkfs.exfat", ["/dev/" <> device])
  # def vfat(device), do: System.cmd("mkfs.vfat", ["/dev/" <> device])
  def f2fs(device), do: System.cmd("mkfs.f2fs", ["-E", "cub", "-f", "/dev/" <> device])
end
