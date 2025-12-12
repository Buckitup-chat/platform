defmodule Platform.Storage.Logic do
  @moduledoc "Storage logic"

  use OriginLog

  alias Chat.Db.Common
  alias Chat.Db.Copying
  alias Chat.Db.Switching
  alias Platform.Tools.Postgres.LogicalReplicator

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
    log("Replicating to internal", :info)

    # Check PG replication lag if enabled
    check_pg_replication_lag()

    case Process.whereis(backup) do
      nil ->
        log("setting mirror: #{inspect(internal)}", :debug)
        Switching.mirror(main, internal)
        Copying.await_copied(main, internal)

      _pid ->
        log("setting mirrors: #{inspect([internal, backup])}", :debug)
        Switching.mirror(main, [internal, backup])
        Copying.await_copied(main, internal)
        # TODO: continious backup need a way for new changes
        # Copying.await_copied(main, backup)
    end

    log("Replicated to internal", :info)
    set_db_flag(replication: false)
  end

  # Check PostgreSQL logical replication lag
  defp check_pg_replication_lag do
    # Check lag for internal_from_main subscription
    case LogicalReplicator.check_replication_lag(
           Chat.InternalRepo,
           "internal_from_main"
         ) do
      {:ok, lag_bytes} ->
        log("PG replication lag=#{lag_bytes} bytes", :debug)

        # If lag is high (>1MB), optionally run a light sync
        if lag_bytes > 1_048_576 do
          log("High PG replication lag detected, consider manual sync", :warning)
        end

      {:error, :subscription_not_found} ->
        log("PG subscription not found, skipping lag check", :debug)

      {:error, reason} ->
        log("Failed to check PG replication lag: #{inspect(reason)}", :error)
    end
  end

  # DB functions

  defp get_db_mode, do: Common.get_chat_db_env(:mode)

  defp set_db_flag(flags) do
    Common.get_chat_db_env(:flags)
    |> Keyword.merge(flags)
    |> then(&Common.put_chat_db_env(:flags, &1))
  end
end
