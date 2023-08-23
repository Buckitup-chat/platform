defmodule Platform.Sensor.Weigh.Polling do
  @moduledoc "Weight sensor polling pipeline"

  require Logger
  alias Platform.Sensor.Weigh.Protocol

  defstruct [:pid, :msg, :error]

  def poll(sensor, name, opts) do
    %__MODULE__{}
    |> open_weight_sensor(sensor, name, opts)
    |> read_values()
    |> close_sensor()
    |> yield_error_or_message()
  end

  defp open_weight_sensor(context, sensor, name, opts) do
    case Protocol.open_port(sensor, name, opts) do
      {:ok, pid} -> %{context | pid: pid}
      x -> %{context | error: x}
    end
  end

  defp read_values(%{error: nil, pid: pid} = context) do
    case Protocol.read_message(pid) do
      {:ok, msg} -> %{context | msg: msg}
      x -> %{context | error: x}
    end
  end

  defp read_values(x), do: x

  defp close_sensor(%{pid: pid} = context) do
    if is_pid(pid) do
      Protocol.close_port(pid)
    end

    context
  end

  defp yield_error_or_message(context) do
    if is_nil(context.msg) do
      log_error(context.error)
      :error
    else
      {:ok, context.msg}
    end
  end

  defp log_error(error) do
    "Error connecting to weight sensor: #{inspect(error, pretty: true)}"
    |> Logger.warning()
  end
end
