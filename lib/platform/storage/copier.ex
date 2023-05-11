defmodule Platform.Storage.Copier do
  @moduledoc """
  Copies data from the target db to current db and vice versa
  """
  use GracefulGenServer

  require Logger

  alias Chat.Db
  alias Chat.Db.Copying
  alias Chat.Ordering

  alias Platform.Leds

  @impl true
  def on_init(args) do
    "[media] Syncing " |> Logger.info()

    target_db = Keyword.get(args, :target_db)
    tasks_name = Keyword.get(args, :tasks_name)
    backup_keys = Keyword.get(args, :backup_keys)
    restoration_keys = Keyword.get(args, :restoration_keys)

    Task.Supervisor.async_nolink(tasks_name, fn ->
      Leds.blink_read()
      Copying.await_copied(target_db, Db.db(), restoration_keys)
      Ordering.reset()
      Leds.blink_write()
      Copying.await_copied(Db.db(), target_db, backup_keys)
      Leds.blink_done()
    end)
    |> Task.await(:infinity)

    "[media] Synced " |> Logger.info()
  end

  @impl true
  def on_exit(_reason, _state) do
    Leds.blink_done()
    Ordering.reset()
  end
end
