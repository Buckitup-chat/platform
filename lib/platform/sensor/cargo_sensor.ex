defmodule Platform.Sensor.CargoSensor do
  @framing {Circuits.UART.Framing.Line, separator: "\r"}

  @spec open_port(String.t(), String.t()) :: {:ok, pid()} | {:error, atom()}
  def open_port(port_name, port_opts) do
    {:ok, pid} = Circuits.UART.start_link()
    port_opts = Keyword.put(port_opts, :framing, @framing)

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
