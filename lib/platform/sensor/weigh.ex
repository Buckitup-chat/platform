defmodule Platform.Sensor.Weigh do
  @moduledoc "Weigh sensor directory and factory"

  alias Platform.Sensor.Weigh.Polling

  @known_sensors %{
    "NCI" => Platform.Sensor.Weigh.Types.NCI,
    "Balena D700" => Platform.Sensor.Weigh.Types.BalenaD700
  }

  @spec supported_types() :: list()
  def supported_types do
    @known_sensors |> Map.keys()
  end

  @spec poll(String.t(), String.t(), Keyword.t()) :: {:ok, any()} | :error
  def poll(type, path, opts) do
    struct(@known_sensors[type])
    |> Polling.poll(path, opts)
  end
end
