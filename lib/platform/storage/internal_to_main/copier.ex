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
    next_supervisor = next_opts |> Keyword.fetch!(:under)
    next_specs = next_opts |> Keyword.fetch!(:run)

    send(self(), :start)

    %{task_in: task_supervisor, task: nil, next: {next_specs, next_supervisor}}
  end

  @impl true
  def on_msg(:start, %{task_in: task_supervisor} = state) do
    "copying internal to main" |> Logger.warn()

    internal = Chat.Db.InternalDb
    main = Chat.Db.MainDb

    Leds.blink_write()

    task =
      Task.Supervisor.async_nolink(task_supervisor, fn ->
        Switching.mirror(internal, main)
        Copying.await_copied(internal, main)
        Switching.set_default(main)
        Process.sleep(1_000)
        Switching.mirror(main, internal)
        DbBrokers.refresh()
        Process.sleep(3_000)
      end)

    {:noreply, %{state | task: task}}
  end

  def on_msg({ref, _}, %{task: %Task{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])

    send(self(), :copied)
    {:noreply, state}
  end

  def on_msg(:copied, %{next: {next_specs, next_supervisor}} = state) do
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
