defmodule Platform.UsbWatcher do
  @moduledoc ""

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
    SystemRegistry.register(min_interval: 1500)
  end

  def start_link(opts) do
    GenServer.start_link(__MODULE__, :ok, Keyword.merge([name: __MODULE__], opts))
  end

  @impl true
  def init(_) do
    subscribe()

    SystemRegistry.match(:_)
    |> filter_state()
    |> tap(fn device_map ->
      device_map
      |> Enum.map(fn {root, partitions} -> first_partition_of(partitions, root) end)
      |> Logic.on_new()
    end)
    |> tap(fn _ -> Chat.Db.WritableUpdater.check() end)
    |> ok()
  end

  @impl true
  def handle_info({:system_registry, :global, devices}, connected_devices) do
    devices
    |> filter_state()
    |> tap(fn updated_devices ->
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

      new_devices
      |> Enum.map(fn {root, devices} ->
        devices
        |> first_partition_of(root)
        |> tap(&Logger.info("New block device found: #{&1}"))
      end)
      |> Logic.on_new()

      removed_devices
      |> Enum.map(fn {root, devices} ->
        devices
        |> first_partition_of(root)
        |> tap(&Logger.info("Block device removed: #{&1}"))
      end)
      |> Logic.on_remove(
        Enum.map(unchanged_devices, fn {root, partitions} ->
          first_partition_of(partitions, root)
        end)
      )
    end)
    |> noreply()
  end

  defp first_partition_of(device_partitions, root_key) do
    device_partitions
    |> List.flatten()
    |> Enum.reject(&(&1 == root_key))
    |> case do
      [] -> root_key
      list -> list |> Enum.sort() |> List.first()
    end
  end

  defp ok(x), do: {:ok, x}
  defp noreply(x), do: {:noreply, x}
end
