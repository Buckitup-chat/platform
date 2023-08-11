defmodule Platform.App.Sync.DriveIndicationTest do
  use ExUnit.Case
  alias Circuits.GPIO
  alias Platform.App.Sync.DriveIndication

  setup do
    {:ok, _pid} = GenServer.start_link(DriveIndication, [], name: DriveIndication)

    on_exit(fn ->
      :timer.sleep(200)

      DriveIndication
      |> Process.whereis()
      |> then(fn
        nil -> nil
        pid -> Process.exit(pid, :normal)
      end)

      :ok
    end)

    :ok
  end

  test "make sure that impedance is off" do
    %{red_pin_ref: red_pin, green_pin_ref: green_pin} = DriveIndication |> :sys.get_state()

    assert 0 = GPIO.read(red_pin)
    assert 0 = GPIO.read(green_pin)
  end

  test "drive_accepted" do
    DriveIndication.drive_accepted()

    %{green_pin_mode: :off, red_pin_mode: :on, red_pin_ref: red_pin, green_pin_ref: green_pin} =
      DriveIndication |> :sys.get_state()

    assert 1 = GPIO.read(red_pin)
    assert 0 = GPIO.read(green_pin)
  end

  test "drive_refused" do
    DriveIndication.drive_refused()

    %{green_pin_mode: :off, red_pin_mode: :blink, red_pin_ref: red_pin, green_pin_ref: green_pin} =
      DriveIndication |> :sys.get_state()

    assert 1 = GPIO.read(red_pin)
    assert 0 = GPIO.read(green_pin)

    :timer.sleep(600)

    assert 0 = GPIO.read(red_pin)
    assert 0 = GPIO.read(green_pin)

    :timer.sleep(600)

    assert 1 = GPIO.read(red_pin)
    assert 0 = GPIO.read(green_pin)

    :timer.sleep(600)

    assert 0 = GPIO.read(red_pin)
    assert 0 = GPIO.read(green_pin)
  end

  test "drive_complete" do
    DriveIndication.drive_complete()

    %{green_pin_mode: :on, red_pin_mode: :off, red_pin_ref: red_pin, green_pin_ref: green_pin} =
      DriveIndication |> :sys.get_state()

    assert 0 = GPIO.read(red_pin)
    assert 1 = GPIO.read(green_pin)
  end

  test "drive_reset" do
    DriveIndication.drive_reset()

    %{green_pin_mode: :off, red_pin_mode: :off, red_pin_ref: red_pin, green_pin_ref: green_pin} =
      DriveIndication |> :sys.get_state()

    assert 0 = GPIO.read(red_pin)
    assert 0 = GPIO.read(green_pin)
  end

  test "reset on terminate" do
    %{red_pin_ref: red_pin, green_pin_ref: green_pin} = DriveIndication |> :sys.get_state()

    DriveIndication.drive_complete()
    DriveIndication |> Process.whereis() |> Process.exit(:normal)

    assert 0 = GPIO.read(red_pin)
    assert 0 = GPIO.read(green_pin)
  end
end
