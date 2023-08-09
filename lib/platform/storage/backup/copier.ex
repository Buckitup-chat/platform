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

  alias Platform.App.Sync.DriveIndication
  alias Platform.Leds
  alias Platform.Storage.Stopper

  @impl true
  def on_init(opts) do
    %{
      task_in: opts |> Keyword.fetch!(:tasks_name),
      continuous?: opts |> Keyword.fetch!(:continuous?),
      task_ref: nil
    }
    |> tap(fn _ -> send(self(), :start) end)
  end

  @impl true
  def on_msg(:start, %{task_in: tasks_name, continuous?: continuous?} = state) do
    "[backup] Syncing " |> Logger.info()

    internal = Chat.Db.InternalDb
    main = Chat.Db.MainDb
    backup = Chat.Db.BackupDb

    set_db_flag(backup: true)

    %{ref: ref} =
      tasks_name
      |> Task.Supervisor.async_nolink(fn ->
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

    {:noreply, %{state | task_ref: ref}}
  end

  def on_msg({ref, _}, %{task_ref: ref} = state) do
    Process.demonitor(ref, [:flush])
    send(self(), :copied)
    {:noreply, state}
  end

  def on_msg(:copied, %{continuous?: continuous?} = state) do
    set_db_flag(backup: false)
    DriveIndication.drive_complete()

    unless continuous? do
      Stopper.start_link(wait: 100)
    end

    "[backup] Synced " |> Logger.info()
    {:noreply, state}
  end

  @impl true
  def on_exit(_reason, _state) do
    internal = Chat.Db.InternalDb
    main = Chat.Db.MainDb

    set_db_flag(backup: false)
    Leds.blink_done()
    DriveIndication.drive_refused()
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
