defmodule Platform.Emulator.Drive.DriveIndication do
  @moduledoc "Emulate indication of GPIO"

  alias Platform.Storage.DriveIndication, as: IndicationServer

  use GracefulGenServer, name: IndicationServer
  require Logger

  @blink_interval 500

  def drive_init, do: GenServer.cast(IndicationServer, :drive_init)

  def drive_accepted, do: GenServer.cast(IndicationServer, :drive_accepted)

  def drive_complete, do: GenServer.cast(IndicationServer, :drive_complete)

  def drive_refused, do: GenServer.cast(IndicationServer, :drive_refused)

  def drive_reset, do: GenServer.cast(IndicationServer, :drive_reset)

  @spec pins() :: %{red: :on | :off, green: :on | :off}
  def pins, do: GenServer.call(IndicationServer, :get_pins)

  @impl true
  def on_init(_opts) do
    %{
      red_pin_ref: nil,
      green_pin_ref: nil,
      red_pin_mode: :off,
      green_pin_mode: :off
    }
    |> tap(fn _ -> Logger.debug("[DriveIndication] started.") end)
  end

  @impl true
  def handle_cast(:drive_init, state) do
    {:noreply, %{state | red_pin_mode: :on, green_pin_mode: :on}}
    |> tap(fn _ -> Logger.debug("[DriveIndication] drive initialized.") end)
  end

  @impl true
  def handle_cast(:drive_accepted, state) do
    {:noreply, %{state | red_pin_mode: :on, green_pin_mode: :off}}
    |> tap(fn _ -> Logger.debug("[DriveIndication] drive accepted.") end)
  end

  @impl true
  def handle_cast(:drive_complete, state) do
    {:noreply, %{state | red_pin_mode: :off, green_pin_mode: :on}}
    |> tap(fn _ -> Logger.debug("[DriveIndication] drive complete.") end)
  end

  @impl true
  def handle_cast(:drive_refused, state) do
    Process.send_after(self(), :blink_red, @blink_interval)

    {:noreply, %{state | red_pin_mode: :blink, green_pin_mode: :off}}
    |> tap(fn _ -> Logger.debug("[DriveIndication] drive refused.") end)
  end

  @impl true
  def handle_cast(:drive_reset, state) do
    {:noreply, %{state | red_pin_mode: :off, green_pin_mode: :off}}
    |> tap(fn _ -> Logger.debug("[DriveIndication] drive reset.") end)
  end

  @impl true
  def handle_call(:get_pins, _, state) do
    %{
      red: state.red_pin_mode,
      green: state.green_pin_mode
    }
    |> then(&{:reply, &1, state})
  end

  @impl true
  def on_msg(:blink_red, %{red_pin_mode: :blink} = state) do
    Process.send_after(self(), :blink_red, @blink_interval)

    {:noreply, state}
  end

  @impl true
  def on_msg(:blink_red, state) do
    {:noreply, state}
  end

  @impl true
  def on_exit(_reason, _state) do
    Logger.debug("[DriveIndication] drive reset. shutting down")
  end
end
