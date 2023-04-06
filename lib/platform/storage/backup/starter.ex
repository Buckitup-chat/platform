defmodule Platform.Storage.Backup.Starter do
  @moduledoc """
  Sets backup flag
  """
  use GenServer

  require Logger

  alias Chat.Db.Common

  def start_link(args) do
    GenServer.start_link(__MODULE__, args, [])
  end

  @impl true
  def init(opts) do
    Logger.info("starting #{__MODULE__}")
    Process.flag(:trap_exit, true)
    flag = Keyword.get(opts, :flag, :backup)
    {:ok, on_start(flag)}
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

  defp on_start(flag) do
    set_db_flag([{flag, true}])
    flag
  end

  defp cleanup(_reason, flag) do
    set_db_flag([{flag, false}])
  end

  defp set_db_flag(flags) do
    Common.get_chat_db_env(:flags)
    |> Keyword.merge(flags)
    |> then(&Common.put_chat_db_env(:flags, &1))
  end
end
