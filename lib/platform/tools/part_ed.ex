defmodule Platform.Tools.PartEd do
  @moduledoc "parted wrapper"

  require Logger

  alias Platform.Tools.PartEd.Print

  def size(partition, details \\ &print/1) do
    {root, num} = partition |> parse_partition_device()

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

  defp parse_partition_device(<<?s, ?d, x>>),
    do: {"sd" <> <<x>>, 0}

  defp parse_partition_device(<<?s, ?d, x>> <> num),
    do: {"sd" <> <<x>>, num |> String.to_integer()}

  defp parse_partition_device("mmcblk" <> <<x>>),
    do: {"mmcblk" <> <<x>>, 0}

  defp parse_partition_device("mmcblk" <> <<x, ?p>> <> num),
    do: {"mmcblk" <> <<x>>, num |> String.to_integer()}

  defp print(device) do
    case parted(device, "unit b print free") do
      {output, 0} -> {:ok, Print.parse(output)}
      e -> e
    end
  end

  defp parted(device, params) do
    System.cmd("parted", ["/dev/" <> device, params])
  end
end
