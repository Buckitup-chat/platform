defmodule Platform.UsbWatcher do
  @moduledoc "Filters system events to provide usb drives plug/unplug events"

  use GenServer

  require Logger

  alias Platform.Storage.Logic

  def filter_state(state) do
    state
    |> get_in([:state, "subsystems", "block"])
    |> Enum.filter(fn
      [:state, "devices", "platform", "scb" | _rest] -> true
      _ -> false
    end)
    |> Enum.map(&Enum.drop(&1, 16))
    |> Enum.reject(fn x -> x == [] end)
    |> Enum.group_by(&List.first(&1))
  end

  def subscribe do
    SystemRegistry.register(min_interval: 2000)
  end

  def start_link(opts) do
    GenServer.start_link(__MODULE__, :ok, Keyword.merge([name: __MODULE__], opts))
  end

  @impl true
  def init(_) do
    Chat.Time.init_time()
    subscribe()

    SystemRegistry.match(:_)
    |> filter_state()
    |> tap(fn device_map ->
      send(self(), {:new, device_map})
    end)
    |> ok()
  end

  @impl true
  def handle_info({:system_registry, :global, devices}, connected_devices) do
    devices
    |> filter_state()
    |> tap(&trigger_device_handling(&1, connected_devices))
    |> noreply()
  end

  def handle_info({:new, [x]}, state), do: handle_info({:new, x}, state)
  def handle_info({:new, x}, state) when x == %{}, do: noreply(state)

  def handle_info({:new, %{} = new_devices}, state) do
    Logger.debug("[usb watcher] New devices found: #{inspect(new_devices)}")

    new_devices
    |> Enum.map(fn {root, devices} ->
      devices
      |> first_partition_of(root)
      |> tap(&Logger.info("[usb watcher] New block device found: #{&1}"))
    end)
    |> Logic.on_new()

    noreply(state)
  end

  def handle_info({:removed, removed_devices, _}, state) when removed_devices == %{},
    do: noreply(state)

  def handle_info({:removed, removed_devices, unchanged_devices}, state) do
    removed_devices
    |> Enum.map(fn {root, devices} ->
      devices
      |> first_partition_of(root)
      |> tap(&Logger.info("[usb watcher] Block device removed: #{&1}"))
    end)
    |> Logic.on_remove(
      Enum.map(unchanged_devices, fn {root, partitions} ->
        first_partition_of(partitions, root)
      end)
    )

    noreply(state)
  end

  defp first_partition_of(devices, _) do
    devices
    |> Enum.map(&List.last/1)
    |> Enum.map(fn path ->
      ~r"^(?<device>sd[a-zA-Z]+)(?<index>\d+)?$"
      |> Regex.named_captures(path)
      |> case do
        %{"device" => device, "index" => ""} -> {device, 1000}
        %{"device" => device, "index" => index} -> {device, index |> String.to_integer()}
        _ -> nil
      end
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Enum.map(fn {device, index_list} ->
      index = index_list |> Enum.min()

      if index == 1000 do
        device
      else
        device <> to_string(index)
      end
    end)
    |> List.first()
  end

  #  defp first_partition_of(device_partitions, root_key) do
  #    Logger.debug("[usb watcher] Device partitions: #{inspect(device_partitions)}")
  #
  #    device_partitions
  #    |> List.flatten()
  #    |> Enum.reject(&(&1 == root_key))
  #    |> case do
  #      [] -> root_key
  #      list -> list |> Enum.sort() |> List.first()
  #    end
  #  end

  defp trigger_device_handling(updated_devices, connected_devices) do
    {new_devices, removed_devices, unchanged_devices} =
      updated_devices
      |> Map.merge(connected_devices)
      |> Enum.reduce({%{}, %{}, %{}}, fn {k, v}, {new, removed, connected} ->
        in_updated = Map.has_key?(updated_devices, k)
        in_connected = Map.has_key?(connected_devices, k)

        cond do
          in_updated and not in_connected -> {new |> Map.put(k, v), removed, connected}
          not in_updated and in_connected -> {new, removed |> Map.put(k, v), connected}
          true -> {new, removed, connected |> Map.put(k, v)}
        end
      end)

    send(self(), {:new, new_devices})
    send(self(), {:removed, removed_devices, unchanged_devices})
  end

  defp ok(x), do: {:ok, x}
  defp noreply(x), do: {:noreply, x}
end
