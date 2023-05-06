defmodule Platform.Storage.InternalToMain.Copier do
  @moduledoc """
  Copies data from internal to main db
  """
  use GracefulGenServer

  require Logger

  alias Chat.Db.Copying
  alias Chat.Db.Switching

  alias Platform.Leds

  @impl true
  def on_init(tasks_name) do
    "copying internal to main" |> Logger.warn()

    internal = Chat.Db.InternalDb
    main = Chat.Db.MainDb

    Leds.blink_write()

    Task.Supervisor.async_nolink(tasks_name, fn ->
      Switching.mirror(internal, main)
      Copying.await_copied(internal, main)
      Switching.set_default(main)
      Process.sleep(1_000)
      Switching.mirror(main, internal)
      Process.sleep(3_000)
    end)
    |> Task.await(:infinity)

    Logger.info("[internal -> main copier] Data moved to external storage")
    Leds.blink_done()
  end

  @impl true
  def on_exit(reason, _state) do
    "copier cleanup #{inspect(reason)}" |> Logger.warn()

    Leds.blink_done()

    Chat.Db.InternalDb
    |> Switching.set_default()
  end
end
