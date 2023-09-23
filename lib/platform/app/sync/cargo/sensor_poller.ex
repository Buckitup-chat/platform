defmodule Platform.App.Sync.Cargo.SensorPoller do
  @moduledoc "Polls cargo sensors"
  use GracefulGenServer, name: __MODULE__

  def table_ref do
    __MODULE__
    |> GenServer.call(:get_table_ref)
  end

  def sensor(ref, key) do
    :ets.lookup(ref, key)
    |> case do
      {key, data, time} -> data
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
      pollers: start_pollers(in: task_supervisor, store_in: ref)
    }
    |> then(&{:noreply, &1})
  end

  @impl true
  def handle_call(:get_table_ref, _from, %{table_ref: ref} = state) do
    {:reply, ref, state}
  end

  @impl true
  def on_exit(reason, %{table_ref: ref}) do
    delete_table(ref)
  end

  defp create_table, do: :etc.new(nil, [:public])
  defp delete_table(ref), do: :ets.delete(ref)

  defp start_pollers(in: task_supervisor, store_in: table) do
    make_sensor_map()
    |> Enum.map(fn {key, getter} ->
      Task.Supervisor.start_child(
        task_supervisor,
        fn -> poll(key, getter, table) end,
        restart: :permanent,
        shutdown: :brutal_kill
      )
    end)
  end

  defp make_sensor_map() do
    %{camera_sensors: sensors, weight_sensor: weight_sensor} = AdminRoom.get_cargo_settings()

    sensor_list =
      sensors
      |> Enum.map(
        &{&1,
         fn sensor ->
           {:ok, {type, content} = data} <- Sensor.get_image(sensor)
           data
         end}
      )

    weight_list =
      if
      |> then(&[&1 | {:weight}])
      |> Enum.map(&fn -> image_sensor_message_db_keys(&1, cargo_user) end)
      |> then(fn funcs ->
        fn -> weight_sensor_message_db_keys(weight_sensor, cargo_user) end
        |> then(&[&1 | funcs])
      end)

      #todo finish weight list
  end

  defp poll(key, getter, table) do
    {time, res} = :timer.tc(fn -> getter.(key) end, :millisecond)
    put_sensor_data(table_ref, key, res)

    delay = 1000 - time

    if delay > 0 do
      Process.sleep(delay)
    end

    poll(key, getter, table)
  end

  defp put_sensor_data(ref, key, data) do
    :ets.insert(ref, {key, data})
  end
end
