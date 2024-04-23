defmodule Platform.Tools.Mkfs do
  @moduledoc "mkfs wrapper"

  alias Platform.Tools.Proto.Device

  # def exfat(device), do: System.cmd("mkfs.exfat", ["/dev/" <> device])
  # def vfat(device), do: System.cmd("mkfs.vfat", ["/dev/" <> device])

  @spec f2fs(device :: Device.t()) :: {output :: String.t(), code :: non_neg_integer()}
  def f2fs(device), do: System.cmd("mkfs.f2fs", ["-E", "cub", "-f", device |> Device.path()])
end
