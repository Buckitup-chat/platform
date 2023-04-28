defmodule Platform.Storage.Backup.Copier do
  @moduledoc """
  Syncs data between backup and current DB
  """
  use GenServer

  require Logger

  alias Chat.Db
  alias Chat.Db.{Common, Copying, Switching}
  alias Chat.Ordering

  alias Platform.Leds
  alias Platform.Storage.Stopper

  def start_link(args) do
    GenServer.start_link(__MODULE__, args, [])
  end

  @impl true
  def init(args) do
    Logger.info("starting #{__MODULE__}")
    Process.flag(:trap_exit, true)
    {:ok, on_start(args)}
  end

  # handle the trapped exit call
  @impl true
  def handle_info({:EXIT, _from, reason}, state) do
    Logger.info("exiting #{__MODULE__}")
    cleanup(reason, state)
    {:stop, reason, state}
  end

  # handle termination
  @impl true
  def terminate(reason, state) do
    Logger.info("terminating #{__MODULE__}")
    cleanup(reason, state)
    state
  end

  defp on_start(opts) do
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

      Leds.blink_done()
    end)
    |> Task.await(:infinity)

    set_db_flag(backup: false)

    unless continuous? do
      Stopper.start_link(wait: 100)
    end

    "[backup] Synced " |> Logger.info()
  end

  defp cleanup(_reason, _state) do
    internal = Chat.Db.InternalDb
    main = Chat.Db.MainDb

    Leds.blink_done()
    Switching.mirror(main, internal)
    Ordering.reset()
  end

  defp set_db_flag(flags) do
    Common.get_chat_db_env(:flags)
    |> Keyword.merge(flags)
    |> then(&Common.put_chat_db_env(:flags, &1))
  end
end
