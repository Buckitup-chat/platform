defmodule Platform.Storage.DriveIndication do
  @moduledoc "Control of GPIO leds"

  use GracefulGenServer, name: __MODULE__
  require Logger

  alias Circuits.GPIO

  @red_led_pin 23
  @green_led_pin 25
  @blink_interval 500

  def drive_accepted, do: GenServer.cast(__MODULE__, :drive_accepted)

  def drive_complete, do: GenServer.cast(__MODULE__, :drive_complete)

  def drive_refused, do: GenServer.cast(__MODULE__, :drive_refused)

  def drive_reset, do: GenServer.cast(__MODULE__, :drive_reset)

  @impl true
  def on_init(_opts) do
    {:ok, red_pin_ref} = GPIO.open(@red_led_pin, :output)
    {:ok, green_pin_ref} = GPIO.open(@green_led_pin, :output)

    # make sure that impedance is off
    GPIO.write(red_pin_ref, 0)
    GPIO.write(green_pin_ref, 0)

    %{
      red_pin_ref: red_pin_ref,
      green_pin_ref: green_pin_ref,
      red_pin_mode: :off,
      green_pin_mode: :off
    }
    |> tap(fn _ -> Logger.debug("[DriveIndication] started.") end)
  end

  @impl true
  def handle_cast(:drive_accepted, %{red_pin_ref: red_pin, green_pin_ref: green_pin} = state) do
    GPIO.write(red_pin, 1)
    GPIO.write(green_pin, 0)

    {:noreply, %{state | red_pin_mode: :on, green_pin_mode: :off}}
    |> tap(fn _ -> Logger.debug("[DriveIndication] drive accepted.") end)
  end

  @impl true
  def handle_cast(:drive_complete, %{red_pin_ref: red_pin, green_pin_ref: green_pin} = state) do
    GPIO.write(red_pin, 0)
    GPIO.write(green_pin, 1)

    {:noreply, %{state | red_pin_mode: :off, green_pin_mode: :on}}
    |> tap(fn _ -> Logger.debug("[DriveIndication] drive complete.") end)
  end

  @impl true
  def handle_cast(:drive_refused, %{red_pin_ref: red_pin, green_pin_ref: green_pin} = state) do
    GPIO.write(red_pin, 1)
    GPIO.write(green_pin, 0)

    Process.send_after(self(), :blink_red, @blink_interval)

    {:noreply, %{state | red_pin_mode: :blink, green_pin_mode: :off}}
    |> tap(fn _ -> Logger.debug("[DriveIndication] drive refused.") end)
  end

  @impl true
  def handle_cast(:drive_reset, %{red_pin_ref: red_pin, green_pin_ref: green_pin} = state) do
    GPIO.write(red_pin, 0)
    GPIO.write(green_pin, 0)

    {:noreply, %{state | red_pin_mode: :off, green_pin_mode: :off}}
    |> tap(fn _ -> Logger.debug("[DriveIndication] drive reset.") end)
  end

  @impl true
  def on_msg(:blink_red, %{red_pin_ref: red_pin, red_pin_mode: :blink} = state) do
    new_value = if Circuits.GPIO.read(red_pin) == 1, do: 0, else: 1
    GPIO.write(red_pin, new_value)

    Process.send_after(self(), :blink_red, @blink_interval)

    {:noreply, state}
  end

  @impl true
  def on_msg(:blink_red, state) do
    {:noreply, state}
  end

  @impl true
  def on_exit(_reason, %{red_pin_ref: red_pin, green_pin_ref: green_pin}) do
    GPIO.write(red_pin, 0)
    GPIO.write(green_pin, 0)
    Logger.debug("[DriveIndication] drive reset.")
  end
end
