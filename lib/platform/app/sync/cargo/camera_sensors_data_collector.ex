defmodule Platform.App.Sync.Cargo.CameraSensorsDataCollector do
  @moduledoc "Collects camera sensors data"

  use GracefulGenServer

  alias Chat.AdminRoom
  alias Chat.Sync.Camera.Sensor
  alias Chat.Sync.CargoRoom

  @impl true
  def on_init(opts) do
    Process.send_after(self(), :perform, 10)

    opts
  end

  @impl true
  def on_msg(:perform, state) do
    keys_holder = Keyword.fetch!(state, :get_keys_from)
    %{me: cargo_user, rooms: [_room_identity]} = GenServer.call(keys_holder, :keys)
    %{camera_sensors: sensors} = AdminRoom.get_cargo_settings()

    keys_set =
      sensors
      |> Stream.map(&Sensor.get_image/1)
      |> Stream.filter(&match?({:ok, _}, &1))
      |> Stream.map(fn {:ok, {type, content}} ->
        {:ok, keys_set} =
          CargoRoom.write_file(
            cargo_user,
            content,
            %{
              "Content-Type" => type,
              "Content-Length" => byte_size(content) |> to_string(),
              "Name-Prefix" => "cargo_shot_"
            }
          )

        keys_set
      end)
      |> Enum.reduce(MapSet.new(), fn set, acc_set -> MapSet.union(acc_set, set) end)

    next = Keyword.fetch!(state, :next)
    next_under = Keyword.fetch!(next, :under)
    next_spec = Keyword.fetch!(next, :run) |> Keyword.put(:keys_set, keys_set)

    Platform.start_next_stage(next_under, next_spec)

    {:noreply, state}
  end

  @impl true
  def on_exit(_reason, _state) do
    CargoRoom.remove()
  end
end
