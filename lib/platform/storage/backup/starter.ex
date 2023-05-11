defmodule Platform.Storage.Backup.Starter do
  @moduledoc """
  Sets backup flag
  """
  use GracefulGenServer

  require Logger

  alias Chat.Db.Common

  @impl true
  def on_init(opts) do
    flag = Keyword.get(opts, :flag, :backup)
    set_db_flag([{flag, true}])
    flag
  end

  @impl true
  def on_exit(_reason, flag) do
    set_db_flag([{flag, false}])
  end

  defp set_db_flag(flags) do
    Common.get_chat_db_env(:flags)
    |> Keyword.merge(flags)
    |> then(&Common.put_chat_db_env(:flags, &1))
  end
end
