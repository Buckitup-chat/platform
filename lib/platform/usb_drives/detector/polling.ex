defmodule Platform.UsbDrives.Detector.Polling do
  @moduledoc "Poll /dev/ to find out device changes"

  def current_device_set do
    "/dev/sd*"
    |> Path.wildcard()
    |> Stream.map(&parse_path/1)
    |> Stream.reject(&is_nil/1)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Enum.map(&first_partition/1)
    |> MapSet.new()
  end

  def changes_against(prev_device_set) do
    current_device_set()
    |> compare_with(prev_device_set)
  end

  defp parse_path(path) do
    ~r"^/dev/(?<device>sd[a-zA-Z]+)(?<index>\d+)?$"
    |> Regex.named_captures(path)
    |> case do
      %{"device" => device, "index" => ""} -> {device, 1000}
      %{"device" => device, "index" => index} -> {device, index |> String.to_integer()}
      _ -> nil
    end
  end

  defp first_partition({device, index_list}) do
    index = index_list |> Enum.min()

    if index == 1000 do
      device
    else
      device <> to_string(index)
    end
  end

  defp compare_with(new, old) do
    added = MapSet.difference(new, old)
    removed = MapSet.difference(old, new)

    {new, added, removed}
  end
end
