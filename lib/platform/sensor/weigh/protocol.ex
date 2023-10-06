defprotocol Platform.Sensor.Weigh.Protocol do
  @spec open_port(sensor :: struct(), path :: String.t(), opts :: Keyword.t()) ::
          {:ok, struct()} | any
  def open_port(sensor, path, opts)

  @spec close_port(sensor :: struct()) :: :ok
  def close_port(sensor)

  def read(sensor)
  def read_message(sensor)
end
