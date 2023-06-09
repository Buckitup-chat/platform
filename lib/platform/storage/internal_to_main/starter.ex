defmodule Platform.Storage.InternalToMain.Starter do
  @moduledoc """
  Indicates transition to main on start. Indicates switch to internal on exit
  """
  use GracefulGenServer

  alias Chat.Db.Common

  @impl true
  def on_init(args) do
    set_db_mode(:internal_to_main)
    args
  end

  @impl true
  def on_exit(_reason, _state) do
    set_db_mode(:internal)
  end

  defp set_db_mode(mode), do: Common.put_chat_db_env(:mode, mode)
end
