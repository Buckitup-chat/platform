defmodule Platform.Tools.Fsck do
  @moduledoc "Fsck wrapper"

  alias Platform.Log
  alias Platform.Tools.Proto.Device

  @spec exfat(device :: Device.t()) :: boolean
  def exfat(device), do: device |> run("fsck.exfat", ["-y"])

  @spec vfat(device :: Device.t()) :: boolean
  def vfat(device), do: device |> run("fsck.vfat", ["-y"])

  @spec f2fs(device :: Device.t()) :: boolean
  def f2fs(device), do: device |> run("fsck.f2fs", ["-y", "-a"])

  defp run(device, cmd, opts) do
    device
    |> Device.path()
    |> then(fn path -> System.cmd(cmd, opts ++ [path]) end)
    |> successful?()
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
