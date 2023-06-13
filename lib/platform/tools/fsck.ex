defmodule Platform.Tools.Fsck do
  @moduledoc "Fsck wrapper"

  alias Platform.Log

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

  defp successful?({msg, exit_code}) do
    case exit_code do
      0 ->
        true

      x ->
        Log.fsck_warn(x, msg)
        false
    end
  end
end
