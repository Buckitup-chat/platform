defmodule Platform.Storage.InternalToMain.Switcher do
  @moduledoc """
  Finalising switching to main
  """
  use GenServer

  require Logger

  alias Chat.Db.Common
  alias Platform.Storage.MainReplicator

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
    "switcher on start #{inspect(args)}" |> Logger.warn()
    set_db_mode(:main)
    MainReplicator.start()
    args
  end

  defp cleanup(reason, _state) do
    "switcher cleanup #{inspect(reason)}" |> Logger.warn()
    set_db_mode(:main_to_internal)
    MainReplicator.stop()
  end

  defp set_db_mode(mode), do: Common.put_chat_db_env(:mode, mode)
end
