defmodule Platform.App.Sync.Cargo.SensorPoller do
  @moduledoc "Polls cargo sensors"
  use GracefulGenServer, name: __MODULE__

  alias Chat.AdminRoom

  def table_ref do
    __MODULE__
    |> GenServer.call(:get_table_ref)
  end

  def sensor(ref, key) do
    :ets.lookup(ref, key)
    |> case do
      {_key, data} -> data
      _ -> nil
    end
  end

  @impl true
  def on_init(opts) do
    task_supervisor = Keyword.fetch!(opts, :task_supervisor)
    send(self(), {:start, task_supervisor})

    %{}
  end

  @impl true
  def on_msg({:start, task_supervisor}, _) do
    ref = create_table()

    %{
      table_ref: ref,
      supervisor: task_supervisor,
      pollers: start_pollers(in: task_supervisor, store_in: ref)
    }
    |> then(&{:noreply, &1})
  end

  @impl true
  def handle_call(:get_table_ref, _from, %{table_ref: ref} = state) do
    {:reply, ref, state}
  end

  @impl true
  def on_exit(_reason, %{} = state) do
    state.pollers
    |> Enum.each(&Task.Supervisor.terminate_child(state.supervisor, &1))

    delete_table(state.table_ref)
  end

  defp create_table, do: :etc.new(nil, [:public])
  defp delete_table(ref), do: :ets.delete(ref)

  defp start_pollers(in: task_supervisor, store_in: table) do
    make_sensor_map()
    |> Enum.map(fn {key, getter} ->
      {:ok, pid} =
        Task.Supervisor.start_child(
          task_supervisor,
          fn -> poll(key, getter, table) end,
          restart: :permanent,
          shutdown: :brutal_kill
        )

      pid
    end)
  end

  defp make_sensor_map() do
    %{camera_sensors: sensors, weight_sensor: weight_sensor} = AdminRoom.get_cargo_settings()

    sensor_list =
      sensors
      |> Enum.map(
        &{&1,
         fn sensor ->
           {:ok, {_, _} = data} = Sensor.get_image(sensor)
           data
         end}
      )

    weight_list =
      case AdminRoom.parse_weight_setting(weight_sensor) do
        {:ok, {name, type, opts}} ->
          [
            {:weight,
             fn _ ->
               {:ok, content} = Platform.Sensor.Weigh.poll(type, name, opts)
               content
             end}
          ]

        _ ->
          []
      end

    Map.new(sensor_list ++ weight_list)
  end

  defp poll(key, getter, table) do
    {time, res} = :timer.tc(fn -> getter.(key) end, :millisecond)
    put_sensor_data(table, key, res)

    delay = 1000 - time

    if delay > 0 do
      Process.sleep(delay)
    end

    poll(key, getter, table)
  rescue
    _ -> poll(key, getter, table)
  end

  defp put_sensor_data(ref, key, data) do
    :ets.insert(ref, {key, data})
  end
end
