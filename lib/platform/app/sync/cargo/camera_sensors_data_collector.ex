defmodule Platform.App.Sync.Cargo.CameraSensorsDataCollector do
  @moduledoc "Collects camera sensors data"

  use GracefulGenServer

  alias Chat.AdminRoom
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

    next = Keyword.fetch!(state, :next)
    next_under = Keyword.fetch!(next, :under)
    next_spec = Keyword.fetch!(next, :run)

    Platform.start_next_stage(next_under, next_spec)

    {:noreply, state}
  end

  @impl true
  def on_exit(_reason, _state) do
    CargoRoom.remove()
  end
end