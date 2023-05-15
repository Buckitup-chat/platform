defmodule Platform.Tools.Fsck do
  @moduledoc "Fsck wrapper"

  def all(device) do
    cond do
      successful?(exfat(device)) -> :ok
      successful?(vfat(device)) -> :ok
      true -> :unsupported_fs
    end
  end

  def exfat(device) do
    System.cmd("fsck.exfat", ["-y", "/dev/" <> device])
  end

  def vfat(device) do
    System.cmd("fsck.vfat", ["-y", "/dev/" <> device])
  end

  defp successful?({_, 0}), do: true
  defp successful?(_), do: false
end
