defmodule Platform.Storage.Backup.Copier do
  @moduledoc """
  Copies data from backup to current db and vice versa
  """
  use GenServer

  require Logger

  alias Chat.Db
  alias Chat.Db.Copying
  alias Chat.Ordering

  alias Platform.Leds

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

  defp on_start(args) do
    "[backup] Syncing " |> Logger.info()

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

    "[backup] Synced " |> Logger.info()
  end

  defp cleanup(_reason, _state) do
    Leds.blink_done()
    Ordering.reset()
  end
end
