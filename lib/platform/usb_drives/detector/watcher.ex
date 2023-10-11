defmodule Platform.UsbDrives.Detector.Watcher do
  @moduledoc "GenServer to watch /dev/ for device changes"

  use GenServer

  alias Platform.UsbDrives.Detector
  alias Platform.UsbDrives.Detector.Polling
  alias Platform.UsbDrives.Detector.State

  @tick 100
  @connect_after 500

  def start_link(opts) do
    GenServer.start_link(__MODULE__, :ok, Keyword.merge([name: __MODULE__], opts))
  end

  @impl true
  def init(_) do
    {:ok, State.new() |> State.put_timer(schedule())}
  end

  @impl true
  def handle_info(:check, %State{timer: timer, devices: devices} = state) do
    {updated_devices, added, removed} = Polling.changes_against(devices)

    if removed |> any?() do
      Detector.log_removed(removed)
    end

    if added |> any?() do
      Detector.log_added(added)
      Detector.start_initial_indication()
    end

    state
    |> terminate_devices(removed)
    |> State.add_connecting(added |> start_connecting_timers())
    |> State.put_devices(updated_devices)
    |> State.put_timer(schedule(timer))
    |> then(&{:noreply, &1})
  end

  def handle_info({:add_connected, device}, %State{} = state) do
    if State.has_device?(state, device) do
      state
      |> State.add_connected(device)
      |> tap(fn _ -> Detector.insert(device) end)
    else
      state
    end
    |> State.discard_connecting([device])
    |> then(&{:noreply, &1})
  end

  def handle_info(_task_results, state), do: {:noreply, state}

  defp terminate_devices(state, devices) do
    devices
    |> Enum.reduce(state, fn device, state ->
      cond do
        State.has_connected?(state, device) ->
          state
          |> tap(&cancel_connecting_timer(&1, device))
          |> State.delete_device(device)
          |> tap(fn _ -> Detector.eject(device) end)

        State.has_connecting?(state, device) ->
          state
          |> tap(&cancel_connecting_timer(&1, device))
          |> State.discard_connecting([device])

        # coveralls-ignore-start
        true ->
          state
          # coveralls-ignore-stop
      end
    end)
  end

  defp start_connecting_timers(devices) do
    devices
    |> Enum.map(&{&1, Process.send_after(self(), {:add_connected, &1}, @connect_after)})
    |> Map.new()
  end

  defp cancel_connecting_timer(state, device) do
    [State.connecting_timer(state, device)]
    |> Enum.reject(&is_nil/1)
    |> Enum.each(&Process.cancel_timer/1)
  end

  defp any?(set), do: MapSet.size(set) > 0

  defp schedule(old_timer \\ nil) do
    if is_reference(old_timer) do
      Process.cancel_timer(old_timer)
    end

    Process.send_after(self(), :check, @tick)
  end
end
