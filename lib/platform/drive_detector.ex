defmodule Platform.DriveDetector do
  @moduledoc "Detects drive insert/eject"

  use GenServer

  require Logger

  defmodule State do
    defstruct devices: MapSet.new(),
              timer: nil,
              connected_devices: MapSet.new()
  end

  alias Platform.DriveDetector.State
  alias Platform.Storage.DriveIndication
  alias Platform.Storage.Logic

  @tick 100
  @connect_after 500

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
    {:ok, %State{timer: schedule()}}
  end

  @impl true
  def handle_info(:check, %State{timer: timer, devices: devices} = state) do
    {updated_devices, added, removed} =
      poll_devices()
      |> compare_with(devices)

    if 0 < MapSet.size(removed), do: process_removed(removed)
    if 0 < MapSet.size(added), do: process_added(added)

    {:noreply, %{state | timer: schedule(timer), devices: updated_devices}}
  end

  def handle_info({:remove_connected, device}, %State{connected_devices: connected} = state) do
    if MapSet.member?(connected, device) do
      connected
      |> MapSet.delete(device)
      |> tap(fn still_connected ->
        Logic.on_remove([device], still_connected |> MapSet.to_list())
      end)
      |> then(&{:noreply, %{state | connected_devices: &1}})
    else
      {:noreply, state}
    end
  end

  def handle_info(
        {:add_connected, device},
        %State{devices: current, connected_devices: connected} = state
      ) do
    if MapSet.member?(current, device) do
      connected
      |> MapSet.put(device)
      |> tap(fn _ ->
        Logic.on_new([device])
      end)
      |> then(&{:noreply, %{state | connected_devices: &1}})
    else
      {:noreply, state}
    end
  end

  def handle_info(_task_results, state), do: {:noreply, state}

  defp compare_with(new, old) do
    added = MapSet.difference(new, old)
    removed = MapSet.difference(old, new)

    {new, added, removed}
  end

  defp process_added(devices) do
    if main_already_inserted?() do
      start_initial_indication()
    end

    devices
    |> Enum.map(&Process.send_after(self(), {:add_connected, &1}, @connect_after))

    devices |> log_added()
  end

  defp main_already_inserted? do
    Chat.Db.Common.get_chat_db_env(:mode) == :main
  end

  defp start_initial_indication do
    Task.Supervisor.async_nolink(Platform.TaskSupervisor, fn ->
      DriveIndication.drive_init()
      Process.sleep(250)
      DriveIndication.drive_reset()
    end)
  end

  defp log_added(devices) do
    Logger.debug("[drive detector] added: " <> Enum.join(devices, ", "))
  end

  defp process_removed(devices) do
    devices
    |> Enum.map(&send(self(), {:remove_connected, &1}))

    Logger.debug("[drive detector] removed: " <> Enum.join(devices, ", "))
  end

  defp schedule(old_timer \\ nil) do
    if old_timer do
      Process.cancel_timer(old_timer)
    end

    Process.send_after(self(), :check, @tick)
  end
end
