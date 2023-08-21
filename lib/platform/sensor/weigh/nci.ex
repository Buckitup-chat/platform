defmodule Platform.Sensor.Weigh.NCI do
  @moduledoc "UART wrapping for NCI protocol of weight sensor"

  defstruct pid: :no_nci_pid
end

defimpl Platform.Sensor.Weigh.Protocol, for: Platform.Sensor.Weigh.NCI do
  alias Platform.Sensor.Weigh.Common
  alias Platform.Sensor.Weigh.NCI

  @impl true
  def open_port(%NCI{}, path, opts) do
    Common.open_port(path, opts)
    |> case do
      {:ok, pid} -> {:ok, %NCI{pid: pid}}
      other -> other
    end
  end

  @impl true
  def close_port(%NCI{pid: pid}) do
    Common.close_port(pid)
    :ok
  end

  @impl true
  def read(%NCI{pid: pid}) do
    with raw <- Common.read_value!(pid, "W\r"),
         {_, {:ok, weight, status_binary}} <- parse_response(raw),
         {_, status} <- parse_status(status_binary) do
      {:ok, weight, status}
    end
  rescue
    e -> {:error, {:unable_to_read_port, e}}
  end

  @impl true
  def read_message(%NCI{} = sensor) do
    case read(sensor) do
      {:ok, weight, status_map} ->
        """
        Weight: #{weight}

        Status: #{summary(status_map)}
        """
        |> then(&{:ok, &1})

      other ->
        other
    end
  end

  defp parse_response(binary),
    do: {:parse_response, Chat.Sync.Weigh.NCI.parse_weight_response(binary)}

  defp parse_status(binary), do: {:parse_status, Chat.Sync.Weigh.NCI.parse_status(binary)}

  defp summary(map) do
    map
    |> Enum.filter(&elem(&1, 1))
    |> Enum.map_join(" ", fn {key, _} ->
      key
      |> to_string()
      |> String.trim_trailing("?")
    end)
  end
end
