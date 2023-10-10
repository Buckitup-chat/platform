defmodule Platform.Storage.Logic do
  @moduledoc "Storage logic"

  require Logger

  alias Chat.Db
  alias Chat.Db.Common
  alias Chat.Db.Copying
  alias Chat.Db.Maintenance
  alias Chat.Db.Switching
  alias Platform.Storage.Device

  def replicate_main_to_internal do
    case get_db_mode() do
      :main_to_internal -> do_replicate_to_internal()
      :main -> do_replicate_to_internal()
      _ -> :ignored
    end
  end

  def info do
    %{
      db: get_db_mode(),
      flags: Common.get_chat_db_env(:flags),
      writable: Common.get_chat_db_env(:writable),
      budget: Common.get_chat_db_env(:write_budget)
    }
  end

  # Implementations

  defp do_replicate_to_internal do
    internal = Chat.Db.InternalDb
    main = Chat.Db.MainDb
    backup = Chat.Db.BackupDb

    set_db_flag(replication: true)
    "[platform] [storage] Replicating to internal" |> Logger.info()

    case Process.whereis(backup) do
      nil ->
        Logger.warn("setting mirror: #{inspect(internal)}")
        Switching.mirror(main, internal)
        Copying.await_copied(main, internal)

      _pid ->
        Logger.warn("setting mirrors: #{inspect([internal, backup])}")
        Switching.mirror(main, [internal, backup])
        Copying.await_copied(main, internal)
        # TODO: continious backup need a way for new changes
        # Copying.await_copied(main, backup)
    end

    "[platform] [storage] Replicated to internal" |> Logger.info()
    set_db_flag(replication: false)
  end

  # DB functions

  defp get_db_mode, do: Common.get_chat_db_env(:mode)

  defp set_db_flag(flags) do
    Common.get_chat_db_env(:flags)
    |> Keyword.merge(flags)
    |> then(&Common.put_chat_db_env(:flags, &1))
  end
end
