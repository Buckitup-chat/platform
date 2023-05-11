defmodule Platform.Storage.InternalToMain.Starter do
  @moduledoc """
  Transition to main starter
  """
  use GracefulGenServer

  require Logger

  alias Chat.Db.Common

  @impl true
  def on_init(args) do
    set_db_mode(:internal_to_main)
    args
  end

  @impl true
  def on_exit(reason, _state) do
    "starter cleanup #{inspect(reason)}" |> Logger.warn()
    set_db_mode(:internal)
  end

  defp set_db_mode(mode), do: Common.put_chat_db_env(:mode, mode)
end
