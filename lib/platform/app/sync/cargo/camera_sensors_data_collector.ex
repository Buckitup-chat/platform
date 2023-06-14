defmodule Platform.App.Sync.Cargo.CameraSensorsDataCollector do
  @moduledoc "Gets the room private key"

  use GracefulGenServer

  alias Chat.AdminRoom
  alias Chat.Sync.CargoRoom

  @impl true
  def on_init(args) do
    keys_holder = Keyword.fetch!(args, :get_keys_from)
    %{me: cargo_user, rooms: [_room_identity]} = GenServer.call(keys_holder, :keys)
    %{camera_sensors: sensors} = AdminRoom.get_cargo_settings()

    sensors
    |> Enum.map(fn url -> HTTPoison.get(url) end)
    |> Enum.each(fn {:ok, %{body: content, headers: headers}} ->
      :ok =
        CargoRoom.write_file(
          cargo_user,
          content,
          headers |> Map.new() |> Map.put("Name-Prefix", "cargo_shot_")
        )
    end)
  end

  @impl true
  def on_exit(_reason, _state) do
    CargoRoom.remove()
  end
end
