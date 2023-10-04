defmodule Platform.Tools.Lsblk do
  @moduledoc "List partition info"

  def fs_type(device) do
    "lsblk"
    |> System.cmd(["-o", "FSTYPE", "/dev/" <> device])
    |> parse_fs_type()
  end

  defp parse_fs_type({output, 0}) do
    "FSTYPE\n" <> type = output
    type |> String.trim_trailing()
  end

  defp parse_fs_type(_), do: :error
end
