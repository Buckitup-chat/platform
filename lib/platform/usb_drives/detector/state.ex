defmodule Platform.UsbDrives.Detector.State do
  @moduledoc "State for Drive Detector"

  defstruct devices: MapSet.new(),
            timer: nil,
            connected_devices: MapSet.new(),
            connecting_timers: %{}

  def new, do: %__MODULE__{}
  def put_timer(%__MODULE__{} = state, timer), do: %{state | timer: timer}
  def put_devices(%__MODULE__{} = state, device_set), do: %{state | devices: device_set}

  def has_device?(%__MODULE__{devices: current}, device), do: MapSet.member?(current, device)

  def has_connected?(%__MODULE__{connected_devices: connected}, device),
    do: MapSet.member?(connected, device)

  def has_connecting?(%__MODULE__{connecting_timers: timers}, device),
    do: Map.has_key?(timers, device)

  def delete_device(%__MODULE__{connected_devices: connected} = state, device) do
    %{state | connected_devices: connected |> MapSet.delete(device)}
    |> discard_connecting([device])
  end

  def discard_connecting(%__MODULE__{connecting_timers: timers} = state, keys),
    do: %{state | connecting_timers: Map.drop(timers, keys)}

  def add_connecting(%__MODULE__{connecting_timers: timers} = state, new_timers) do
    %{state | connecting_timers: Map.merge(timers, new_timers)}
  end

  def connecting_timer(%__MODULE__{connecting_timers: timers}, device),
    do: Map.get(timers, device, nil)

  def add_connected(%__MODULE__{connected_devices: connected} = state, device),
    do: %{state | connected_devices: connected |> MapSet.put(device)}
end
