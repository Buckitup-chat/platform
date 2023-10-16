defmodule Platform.Storage.InternalToMain.Switcher do
  @moduledoc """
  Finalising switching to main
  """
  use GracefulGenServer

  require Logger

  alias Chat.Db.Common

  @impl true
  def on_init(args) do
    "switcher on start #{inspect(args)}" |> Logger.warning()
    set_db_mode(:main)
    args
  end

  @impl true
  def on_exit(reason, _state) do
    "switcher cleanup #{inspect(reason)}" |> Logger.warning()
    set_db_mode(:main_to_internal)
  end

  defp set_db_mode(mode), do: Common.put_chat_db_env(:mode, mode)
end
