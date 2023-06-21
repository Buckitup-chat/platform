defmodule Platform.App.Sync.Cargo.IndicationTest do
  use ExUnit.Case
  alias Circuits.GPIO
  alias Platform.App.Sync.Cargo.Indication

  setup do
    {:ok, _pid} = GenServer.start_link(Indication, [], name: Indication)

    on_exit(fn ->
      :timer.sleep(200)

      Indicaion
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
    %{red_pin_ref: red_pin, green_pin_ref: green_pin} = Indication |> :sys.get_state()

    assert 0 = GPIO.read(red_pin)
    assert 0 = GPIO.read(green_pin)
  end

  test "drive_accepted" do
    Indication.drive_accepted()

    %{green_pin_mode: :off, red_pin_mode: :on, red_pin_ref: red_pin, green_pin_ref: green_pin} =
      Indication |> :sys.get_state()

    assert 1 = GPIO.read(red_pin)
    assert 0 = GPIO.read(green_pin)
  end

  test "drive_refused" do
    Indication.drive_refused()

    %{green_pin_mode: :off, red_pin_mode: :blink, red_pin_ref: red_pin, green_pin_ref: green_pin} =
      Indication |> :sys.get_state()

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
    Indication.drive_complete()

    %{green_pin_mode: :on, red_pin_mode: :off, red_pin_ref: red_pin, green_pin_ref: green_pin} =
      Indication |> :sys.get_state()

    assert 0 = GPIO.read(red_pin)
    assert 1 = GPIO.read(green_pin)
  end

  test "drive_reset" do
    Indication.drive_reset()

    %{green_pin_mode: :off, red_pin_mode: :off, red_pin_ref: red_pin, green_pin_ref: green_pin} =
      Indication |> :sys.get_state()

    assert 0 = GPIO.read(red_pin)
    assert 0 = GPIO.read(green_pin)
  end

  test "reset on terminate" do
    %{red_pin_ref: red_pin, green_pin_ref: green_pin} = Indication |> :sys.get_state()

    Indication.drive_complete()
    Indication |> Process.whereis() |> Process.exit(:normal)

    assert 0 = GPIO.read(red_pin)
    assert 0 = GPIO.read(green_pin)
  end
end
