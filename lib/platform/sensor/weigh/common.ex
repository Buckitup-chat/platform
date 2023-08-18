defmodule Platform.Sensor.Weigh.Common do
  @moduledoc "UART handling functions"

  alias Circuits.UART

  @read_timeout 500

  def open_port(path, opts) do
    {:ok, pid} = UART.start_link()

    case UART.open(pid, path, opts) do
      :ok ->
        {:ok, pid}

      error ->
        close_port(pid)

        error
    end
  end

  def close_port(pid), do: UART.stop(pid)

  def read_value!(pid, command) do
    :ok = UART.write(pid, command)
    :ok = UART.drain(pid)
    {:ok, value} = UART.read(pid, @read_timeout)
    value
  end
end
