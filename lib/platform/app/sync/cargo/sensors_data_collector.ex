defmodule Platform.App.Sync.Cargo.SensorsDataCollector do
  @moduledoc "Collects camera sensors data"

  use GracefulGenServer, name: __MODULE__

  require Logger

  alias Chat.AdminRoom
  alias Chat.Db
  alias Chat.Db.Copying
  alias Chat.Sync.Camera.Sensor
  alias Chat.Sync.CargoRoom

  @impl true
  def on_init(opts) do
    send(self(), :perform)

    opts
  end

  @impl true
  def on_msg(:perform, state) do
    keys_holder = Keyword.fetch!(state, :get_keys_from)

    %{me: cargo_user, rooms: [_room_identity]} = GenServer.call(keys_holder, :keys)
    %{camera_sensors: sensors} = AdminRoom.get_cargo_settings()

    db_keys =
      sensors
      |> Task.async_stream(&gather_sensor_message_db_keys(&1, cargo_user),
        timeout: 10_000,
        max_concurrency: 20
      )
      |> Enum.reduce(MapSet.new(), fn
        {:ok, set}, acc_set -> MapSet.union(acc_set, set)
        {:error, _}, acc -> acc
      end)
      |> MapSet.to_list()

    db_keys
    |> Copying.await_written_into(Db.db())
    |> case do
      {:stuck, progress} -> log_unwritten_keys(progress)
      _ -> :ok
    end

    send(self(), :run_next)

    {:noreply, state |> Keyword.put(:scope, {db_keys, []})}
  end

  def on_msg(:run_next, state) do
    next = Keyword.fetch!(state, :next)
    next_under = Keyword.fetch!(next, :under)
    next_spec = Keyword.fetch!(next, :run)

    Platform.start_next_stage(next_under, next_spec)

    {:noreply, state}
  end

  @impl true
  def handle_call(:db_keys, _from, state) do
    {:reply, state |> Keyword.get(:scope, {[], []}), state}
  end

  @impl true
  def on_exit(_reason, _state) do
    CargoRoom.remove()
  end

  defp gather_sensor_message_db_keys(sensor, cargo_user) do
    with {:ok, {type, content}} <- Sensor.get_image(sensor),
         size_string <- byte_size(content) |> to_string(),
         headers <- %{"Content-Type" => type, "Content-Length" => size_string},
         {:ok, keys_set} <- CargoRoom.write_file(cargo_user, content, headers) do
      keys_set
    else
      _ -> MapSet.new()
    end
  end

  defp log_unwritten_keys(progress) do
    Copying.Progress.get_unwritten_keys(progress)
    |> inspect(pretty: true)
    |> then(&Logger.warn(["[cargo] [sensor] unwritten keys: ", &1]))
  end
end
