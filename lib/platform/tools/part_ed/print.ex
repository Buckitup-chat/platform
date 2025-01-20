defmodule Platform.Tools.PartEd.Print do
  @moduledoc "Parted print format parsing"
  defstruct [:name, :size, :sector_size, partitions: []]

  def parse(output) do
    [header, list] = output |> String.trim() |> String.split("\n\n")

    header
    |> parse_print_header()
    |> Map.put(:partitions, list |> parse_print_list())
  end

  defp parse_print_header(header) do
    header
    |> String.split("\n")
    |> Enum.reduce(%__MODULE__{}, fn
      "Model: " <> name, acc ->
        %{acc | name: name}

      "Disk /dev/" <> rest, acc ->
        size = rest |> String.split(":") |> Enum.at(1) |> bytes()
        %{acc | size: size}

      "Sector size (" <> rest, acc ->
        size =
          rest
          |> String.split(":")
          |> Enum.at(1)
          |> bytes()

        %{acc | sector_size: size}

      _, acc ->
        acc
    end)
  end

  defp parse_print_list(list) do
    list
    |> String.split("Flags\n", parts: 2)
    |> Enum.at(1)
    |> String.split("\n")
    |> Enum.map(fn
      "   " <> line ->
        line
        |> String.split(" ", trim: true)
        |> Enum.take(3)
        |> Enum.map(&bytes/1)
        |> then(&[:free | &1])
        |> List.to_tuple()

      line ->
        line
        |> String.split(" ", trim: true)
        |> Enum.take(5)
        |> then(fn x ->
          x
          |> Enum.take(4)
          |> Enum.map(&bytes/1)
          |> then(fn list ->
            partition_type = (Enum.at(x, 4) == "primary" && :primary) || :logical
            list ++ [partition_type]
          end)
          |> List.to_tuple()
        end)
    end)
  end

  defp bytes(str) do
    str
    |> String.split("B")
    |> List.first()
    |> String.trim()
    |> String.to_integer()
  end
end
