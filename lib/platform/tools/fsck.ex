defmodule Platform.Tools.Fsck do
  @moduledoc "Fsck wrapper"

  alias Platform.Log

  def exfat(device), do: System.cmd("fsck.exfat", ["-y", "/dev/" <> device]) |> successful?()
  def vfat(device), do: System.cmd("fsck.vfat", ["-y", "/dev/" <> device]) |> successful?()
  def f2fs(device), do: System.cmd("fsck.f2fs", ["-y", "-a", "/dev/" <> device]) |> successful?()

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
