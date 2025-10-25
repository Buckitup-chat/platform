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
    switch_db_repo(args)
  end

  @impl true
  def on_exit(reason, state) do
    "switcher cleanup #{inspect(reason)}" |> Logger.warning()
    set_db_mode(:main_to_internal)
    revert_db_repo(state)
  end

  defp set_db_mode(mode), do: Common.put_chat_db_env(:mode, mode)

  defp switch_db_repo(args) do
    with pg_opts <- Keyword.get(args, :pg_opts),
         false <- is_nil(pg_opts),
         repo <- Map.get(pg_opts, :repo),
         false <- is_nil(repo),
         original_repo <- Chat.Repo.get_dynamic_repo() do
      Chat.Db.set_repo(repo)
      Keyword.put(args, :original_repo, original_repo)
    else
      _ -> args
    end
  end

  defp revert_db_repo(args) do
    with original_repo <- Keyword.get(args, :original_repo),
         false <- is_nil(original_repo) do
      Chat.Db.set_repo(original_repo)
    end
  end
end
