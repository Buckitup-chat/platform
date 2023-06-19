defmodule Platform.Storage.Copier do
  @moduledoc """
  Copies data from the target db to current db and vice versa

  Required options:
    - target: db_pid 
    - task_in: Task.Supervisor
    - get_db_keys_from: GenServer that returns {backup_keys, restoration_keys} on :db_keys call 
    - next: [under: DynamicSupervisor, run: supervisor_children]
  """
  use GracefulGenServer

  require Logger

  alias Chat.Db
  alias Chat.Db.Copying
  alias Chat.Ordering

  alias Platform.Leds

  @impl true
  def on_init(opts) do
    "Copier start" |> Logger.info()

    next = Keyword.fetch!(opts, :next)
    Process.send_after(self(), :start, 10)

    %{
      target_db: Keyword.fetch!(opts, :target),
      task_in: Keyword.fetch!(opts, :task_in),
      db_keys_provider: Keyword.fetch!(opts, :get_db_keys_from),
      next_run: Keyword.fetch!(next, :run),
      next_under: Keyword.fetch!(next, :under),
      task_ref: nil
    }
  end

  @impl true
  def on_msg(
        :start,
        %{
          target_db: target_db,
          task_in: task_supervisor,
          db_keys_provider: db_keys_provider
        } = state
      ) do
    "[media] Syncing " |> Logger.info()

    {backup_keys, restoration_keys} = GenServer.call(db_keys_provider, :db_keys)

    %{ref: ref} =
      Task.Supervisor.async_nolink(task_supervisor, fn ->
        Leds.blink_read()
        Copying.await_copied(target_db, Db.db(), restoration_keys)
        Ordering.reset()
        Leds.blink_write()
        Copying.await_copied(Db.db(), target_db, backup_keys)
        Leds.blink_done()
      end)

    {:noreply, %{state | task_ref: ref}}
  end

  def on_msg({ref, _}, %{task_ref: ref} = state) do
    Process.demonitor(ref, [:flush])
    send(self(), :copied)
    {:noreply, state}
  end

  def on_msg(:copied, %{next_run: next_spec, next_under: next_supervisor} = state) do
    "[media] Synced " |> Logger.info()

    Platform.start_next_stage(next_supervisor, next_spec)

    {:noreply, state}
  end

  @impl true
  def on_exit(_reason, _state) do
    Leds.blink_done()
    Ordering.reset()
  end
end
