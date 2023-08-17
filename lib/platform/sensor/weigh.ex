defmodule Platform.Sensor.Weigh do
  @moduledoc "Weigh sensor directory and factory"

  alias Platform.Sensor.Weigh.Protocol

  @known_sensors %{
    "NCI" => Platform.Sensor.Weigh.NCI,
    "Balena D700" => Platform.Sensor.Weigh.BalenaD700
  }

  @spec new(String.t(), String.t(), Keyword.t()) :: {:ok, struct()} | any()
  def new(type, path, opts) do
    struct(@known_sensors[type])
    |> Protocol.open_port(path, opts)
  end

  @spec supported_types() :: list()
  def supported_types do
    @known_sensors |> Map.keys()
  end
end
