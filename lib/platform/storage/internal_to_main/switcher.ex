defmodule Platform.Storage.InternalToMain.Switcher do
  @moduledoc """
  Finalising switching to main
  """
  use GracefulGenServer
  use OriginLog

  alias Chat.Db.Common
  alias Platform.Tools.Postgres.LogicalReplicator

  @impl true
  def on_init(args) do
    log("on start #{inspect(args)}", :warning)
    set_db_mode(:main)
    switch_pg_replication(args)
    switch_db_repo(args)
  end

  @impl true
  def on_exit(reason, state) do
    log("cleanup #{inspect(reason)}", :warning)
    set_db_mode(:main_to_internal)
    disable_pg_replication(state)
    revert_db_repo(state)
  end

  defp set_db_mode(mode), do: Common.put_chat_db_env(:mode, mode)

  # Switch PG replication from internal→main to main→internal
  defp switch_pg_replication(args) do
    with pg_opts <- Keyword.get(args, :pg_opts),
         false <- is_nil(pg_opts),
         main_repo <- Map.get(pg_opts, :repo),
         false <- is_nil(main_repo),
         main_port <- Map.get(pg_opts, :port) do
      # Disable internal→main subscription on main repo
      _ = LogicalReplicator.disable_subscription(main_repo, "main_from_internal")

      # Sync existing users from main→internal before setting up replication
      # This ensures any users created on USB before this session are copied
      _ =
        Platform.Storage.Sync.run_local_sync(
          source_repo: main_repo,
          target_repo: Chat.InternalRepo,
          schemas: Platform.Storage.Sync.schemas()
        )

      # Create publication on main for main→internal
      _ = LogicalReplicator.create_publication(main_repo, ["users"], "main_to_internal")

      # Create subscription on internal for main→internal
      # Use port from pg_opts since repo.config() may have compile-time port
      conn_string = Platform.Tools.Postgres.build_connection_string(main_repo, port: main_port)

      case LogicalReplicator.create_subscription(
             Chat.InternalRepo,
             conn_string,
             "main_to_internal",
             "internal_from_main",
             copy_data: false,
             # Create disabled, enable after ensuring slot
             enabled: false
           ) do
        :ok ->
          # Ensure slot exists on source (main) before enabling subscription
          _ = LogicalReplicator.ensure_slot_on_source(main_repo, "internal_from_main")
          _ = LogicalReplicator.enable_subscription(Chat.InternalRepo, "internal_from_main")
          log("PG replication switched to main→internal", :info)

        {:error, reason} ->
          log("Failed to create internal_from_main subscription: #{inspect(reason)}", :error)
      end
    else
      _ ->
        log("PG replication not configured, skipping", :debug)
    end
  end

  # Disable main→internal replication when USB is ejected
  # USB repo is expected to be down - just clean up internal side
  defp disable_pg_replication(_state) do
    # Disable main→internal subscription on internal repo
    # This stops internal from trying to connect to the dead USB postgres
    _ = LogicalReplicator.disable_subscription(Chat.InternalRepo, "internal_from_main")
    log("PG replication disabled on internal (USB ejected)", :info)

    # Note: We don't try to re-enable main_from_internal on USB repo
    # because the USB is ejected and the repo is down. The subscription
    # will be re-enabled next time USB is inserted and copier runs.
  end

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
    |> tap(fn _ -> Chat.Sync.DbBrokers.refresh() end)
  end

  defp revert_db_repo(args) do
    with original_repo <- Keyword.get(args, :original_repo),
         false <- is_nil(original_repo) do
      Chat.Db.set_repo(original_repo)
    end
    |> tap(fn _ -> Chat.Sync.DbBrokers.refresh() end)
  end
end
