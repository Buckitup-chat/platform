defmodule Platform.Storage.InternalToMain.Copier do
  @moduledoc """
  Copies data from internal to main db
  """
  use GracefulGenServer

  require Logger

  alias Chat.Db.Copying
  alias Chat.Db.Switching
  alias Chat.Sync.DbBrokers

  alias Platform.Leds

  @impl true
  def on_init(opts) do
    task_supervisor = opts |> Keyword.fetch!(:task_in)
    next_opts = opts |> Keyword.fetch!(:next)
    next_supervisor = opts |> Keyword.fetch!(:under)
    next_specs = opts |> Keyword.fetch!(:run)

    Process.send_after(self(), :start, 10)

    {task_supervisor, next_specs, next_supervisor}
  end

  @impl true
  def on_msg(:start, {task_supervisor, next_specs, next_supervisor} = state) do
    "copying internal to main" |> Logger.warn()

    internal = Chat.Db.InternalDb
    main = Chat.Db.MainDb

    Leds.blink_write()

    Task.Supervisor.async_nolink(task_supervisor, fn ->
      Switching.mirror(internal, main)
      Copying.await_copied(internal, main)
      Switching.set_default(main)
      Process.sleep(1_000)
      Switching.mirror(main, internal)
      Process.sleep(3_000)
      DbBrokers.refresh()
    end)
    |> Task.await(:infinity)

    Logger.info("[internal -> main copier] Data moved to external storage")
    Leds.blink_done()

    Platform.start_next_stage(next_supervisor, next_specs)

    {:noreply, state}
  end

  @impl true
  def on_exit(reason, _state) do
    "copier cleanup #{inspect(reason)}" |> Logger.warn()

    Leds.blink_done()

    Chat.Db.InternalDb
    |> Switching.set_default()

    DbBrokers.refresh()
  end
end
