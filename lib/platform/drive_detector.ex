defmodule Platform.DriveDetector do
  @moduledoc "Detects drive insert/eject"

  use GenServer

  require Logger

  @tick 100

  def poll_devices do
    Path.wildcard("/dev/sd*")
    |> Stream.map(fn path ->
      ~r"^/dev/(?<device>sd[a-zA-Z]+)(?<index>\d+)?$"
      |> Regex.named_captures(path)
      |> case do
        %{"device" => device, "index" => ""} -> {device, 1000}
        %{"device" => device, "index" => index} -> {device, index |> String.to_integer()}
        _ -> nil
      end
    end)
    |> Stream.reject(&is_nil/1)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Enum.map(fn {device, index_list} ->
      index = index_list |> Enum.min()

      if index == 1000 do
        device
      else
        device <> to_string(index)
      end
    end)
    |> MapSet.new()
  end

  def start_link(opts) do
    GenServer.start_link(__MODULE__, :ok, Keyword.merge([name: __MODULE__], opts))
  end

  @impl true
  def init(_) do
    {:ok, {schedule(), MapSet.new()}}
  end

  @impl true
  def handle_info(:check, {timer, devices}) do
    {updated_devices, added, removed} =
      poll_devices()
      |> compare_with(devices)

    if 0 < MapSet.size(removed), do: process_removed(removed)
    if 0 < MapSet.size(added), do: process_added(added)

    {:noreply, {schedule(timer), updated_devices}}
  end

  defp compare_with(new, old) do
    added = MapSet.difference(new, old)
    removed = MapSet.difference(old, new)

    {new, added, removed}
  end

  defp process_added(devices) do
    Logger.debug("[drive detector] added: " <> Enum.join(devices, ", "))
  end

  defp process_removed(devices) do
    Logger.debug("[drive detector] removed: " <> Enum.join(devices, ", "))
  end

  defp schedule(old_timer \\ nil) do
    if old_timer do
      Process.cancel_timer(old_timer)
    end

    Process.send_after(self(), :check, @tick)
  end
end
