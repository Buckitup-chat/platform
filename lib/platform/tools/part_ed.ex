defmodule Platform.Tools.PartEd do
  @moduledoc "parted wrapper"

  require Logger

  alias Platform.Tools.PartEd.Print
  alias Platform.Tools.Proto.Device

  def size(partition, details \\ &print/1) do
    {root, num} = partition |> Device.name() |> parse_partition_device()

    case details.(root) do
      {:ok, device_details} ->
        if num == 0 do
          device_details.size
        else
          device_details.partitions
          |> Enum.find(&(elem(&1, 0) == num))
          |> elem(3)
        end

      error ->
        error
        |> inspect(pretty: true)
        |> Logger.notice()

        0
    end
  end

  defp parse_partition_device(raw) do
    case raw do
      <<?s, ?d, x>> -> {"sd" <> <<x>>, 0}
      <<?s, ?d, x>> <> num -> {"sd" <> <<x>>, num |> String.to_integer()}
      "mmcblk" <> <<x>> -> {"mmcblk" <> <<x>>, 0}
      "mmcblk" <> <<x, ?p>> <> num -> {"mmcblk" <> <<x>>, num |> String.to_integer()}
    end
  end

  defp print(device) do
    case parted(device, "unit b print free") do
      {output, 0} -> {:ok, Print.parse(output)}
      e -> e
    end
  end

  defp parted(device, params) do
    System.cmd("parted", [device |> Device.path(), params])
  end
end
