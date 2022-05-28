defmodule Platform.UsbWatcher do
  @moduledoc ""

  use GenServer

  require Logger

  alias Platform.Sync
  alias Platform.Tools.Mount
  alias Platform.Tools.PartEd

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

  def switch_storage(devices) do
    devices
    |> Enum.map(fn {root, partitiions} ->
      partitiions
      |> first_partition_of(root)
      |> zip_partition_size()
    end)
    |> find_max()
    |> use_as_main_storage()
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
    |> tap(&switch_storage/1)
    |> ok()
  end

  @impl true
  def handle_info({:system_registry, :global, devices}, connected_devices) do
    devices
    |> filter_state()
    |> tap(fn updated_devices ->
      updated_devices
      |> keys_absent_in(connected_devices)
      |> Enum.each(fn key ->
        updated_devices[key]
        |> first_partition_of(key)
        |> tap(&Logger.info("New block device found: #{&1}"))
        |> Sync.sync()
      end)
    end)
    |> noreply()
  end

  defp keys_absent_in(new, old) do
    new
    |> Map.keys()
    |> MapSet.new()
    |> MapSet.difference(old |> Map.keys() |> MapSet.new())
    |> MapSet.to_list()
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

  defp zip_partition_size(device) do
    {device, device |> PartEd.size()}
  end

  defp use_as_main_storage({device, size}) do
    current_size =
      "/root"
      |> Mount.device()
      |> PartEd.size()

    if current_size < size do
      Sync.switch_storage_to(device)
    end
  end

  defp use_as_main_storage(_), do: nil

  defp find_max([]), do: nil
  defp find_max([x]), do: x
  defp find_max(list), do: Enum.max_by(list, &elem(&1, 1))

  defp ok(x), do: {:ok, x}
  defp noreply(x), do: {:noreply, x}
end
