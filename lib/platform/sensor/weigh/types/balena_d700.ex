defmodule Platform.Sensor.Weigh.Types.BalenaD700 do
  @moduledoc "Weight sensor for Balena D700"

  defstruct pid: :no_d700_pid
end

defimpl Platform.Sensor.Weigh.Protocol, for: Platform.Sensor.Weigh.Types.BalenaD700 do
  alias Platform.Sensor.Weigh.Common
  alias Platform.Sensor.Weigh.Types.BalenaD700

  @framing {Circuits.UART.Framing.Line, separator: "\r"}

  @impl true
  def open_port(%BalenaD700{}, port_name, port_opts) do
    port_opts = Keyword.put(port_opts, :framing, @framing)

    Common.open_port(port_name, port_opts)
    |> case do
      {:ok, pid} -> %BalenaD700{pid: pid}
      other -> other
    end
  end

  @impl true
  def close_port(%BalenaD700{pid: pid}) do
    Common.close_port(pid)
  end

  @impl true
  def read(%BalenaD700{pid: pid}) do
    status = Common.read_value!(pid, "XS") |> String.trim()
    weight = Common.read_value!(pid, "XN") |> String.trim()
    {:ok, weight, %{raw: status}}
  rescue
    _ -> {:error, :unable_to_read_port}
  end

  @impl true
  def read_message(%BalenaD700{} = sensor) do
    case read(sensor) do
      {:ok, weight, _status_map} ->
        """
        Weight: #{weight}
        """
        |> then(&{:ok, &1})

      other ->
        other
    end
  end
end
