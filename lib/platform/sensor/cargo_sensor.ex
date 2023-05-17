defmodule Platform.Sensor.CargoSensor do
  @port_name "/dev/ttyACM0"
  @port_opts [
    active: false,
    speed: 115_200,
    data_bits: 8,
    stop_bits: 1,
    parity: :none,
    flow_control: :none,
    framing: {Circuits.UART.Framing.Line, separator: "\r"}
  ]

  @spec open_port(String.t(), String.t()) :: {:ok, pid()} | {:error, atom()}
  def open_port(port_name \\ @port_name, port_opts \\ @port_opts) do
    {:ok, pid} = Circuits.UART.start_link()

    case Circuits.UART.open(pid, port_name, port_opts) do
      :ok -> {:ok, pid}
      error -> error
    end
  end

  @spec read(pid()) :: {String.t(), String.t()}
  def read(pid) do
    status = read_value(pid, "XS")
    weight = read_value(pid, "XN")
    {weight, status}
  end

  defp read_value(pid, command) do
    :ok = Circuits.UART.write(pid, command)
    :ok = Circuits.UART.drain(pid)
    {:ok, value} = Circuits.UART.read(pid)
    value |> String.trim()
  end
end
