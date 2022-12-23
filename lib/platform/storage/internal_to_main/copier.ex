defmodule Platform.Storage.InternalToMain.Copier do
  @moduledoc """
  Copies data from internal to main db
  """
  use GenServer

  require Logger

  alias Chat.Db.Copying
  alias Chat.Db.Switching

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

  defp on_start(tasks_name) do
    "copying internal to main" |> Logger.warn()

    internal = Chat.Db.InternalDb
    main = Chat.Db.MainDb

    Task.Supervisor.async_nolink(tasks_name, fn ->
      Switching.mirror(internal, main)
      Copying.await_copied(internal, main)
      Switching.set_default(main)
      Process.sleep(500)
      Switching.mirror(main, internal)
    end)
    |> Task.await()

    Logger.info("[internal -> main copier] Data moved to external storage")
  end

  defp cleanup(reason, _state) do
    "copier cleanup #{inspect(reason)}" |> Logger.warn()

    Chat.Db.InternalDb
    |> Switching.set_default()
  end
end
