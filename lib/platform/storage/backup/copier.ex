defmodule Platform.Storage.Backup.Copier do
  @moduledoc """
  Syncs data between backup and current DB
  """
  use GracefulGenServer

  require Logger

  alias Chat.Db
  alias Chat.Db.{Common, Copying, Switching}
  alias Chat.Ordering
  alias Chat.Sync.DbBrokers

  alias Platform.Leds
  alias Platform.Storage.Stopper

  @impl true
  def on_init(opts) do
    "[backup] Syncing " |> Logger.info()

    tasks_name = Keyword.get(opts, :tasks_name)
    continuous? = Keyword.get(opts, :continuous?)

    internal = Chat.Db.InternalDb
    main = Chat.Db.MainDb
    backup = Chat.Db.BackupDb

    set_db_flag(backup: true)

    Task.Supervisor.async_nolink(tasks_name, fn ->
      Leds.blink_read()
      Copying.await_copied(Chat.Db.BackupDb, Db.db())
      Ordering.reset()
      Leds.blink_write()
      Copying.await_copied(Db.db(), Chat.Db.BackupDb)

      if continuous? do
        Process.sleep(1_000)
        Switching.mirror(main, [internal, backup])
        Process.sleep(3_000)
      end

      DbBrokers.refresh()
      Leds.blink_done()
    end)
    |> Task.await(:infinity)

    set_db_flag(backup: false)

    unless continuous? do
      Stopper.start_link(wait: 100)
    end

    "[backup] Synced " |> Logger.info()
  end

  @impl true
  def on_exit(_reason, _state) do
    internal = Chat.Db.InternalDb
    main = Chat.Db.MainDb

    Leds.blink_done()
    Switching.mirror(main, internal)
    Ordering.reset()
    DbBrokers.refresh()
  end

  defp set_db_flag(flags) do
    Common.get_chat_db_env(:flags)
    |> Keyword.merge(flags)
    |> then(&Common.put_chat_db_env(:flags, &1))
  end
end
