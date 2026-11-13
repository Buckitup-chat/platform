defmodule Platform.Storage.InternalToMain.Switcher do
  @moduledoc """
  Finalising switching to main
  """
  use GracefulGenServer
  use Toolbox.OriginLog

  alias Chat.Data.Shapes
  alias Chat.Db.Common
  alias Chat.Db.Switching
  alias Chat.Storage.Default
  alias Chat.Storage.Pg
  alias Chat.Storage.Pg.LogicalReplicator
  alias Chat.Storage.Unit
  alias Chat.Storage.Units
  alias Platform.Storage.Sync

  @impl true
  def on_init(args) do
    log("on start #{inspect(args)}", :warning)
    set_db_mode(:main)
    switch_pg_replication(args)
    switch_default_to_main(args)
    args
  end

  @impl true
  def on_exit(reason, state) do
    log("cleanup #{inspect(reason)} state=#{inspect(state)}", :warning)
    set_db_mode(:main_to_internal)

    try do
      disable_pg_replication(state)
    catch
      kind, error ->
        log("disable_pg_replication failed: #{kind} #{inspect(error)}", :error)
    end

    try do
      Default.switch_to(Unit.internal())
    catch
      kind, error ->
        log("switching Default back to internal failed: #{kind} #{inspect(error)}", :error)
    end

    log("cleanup done", :warning)
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
        Sync.run_local_sync(
          source_repo: main_repo,
          target_repo: Chat.Repo,
          schemas: Sync.schemas()
        )

      _ = LogicalReplicator.drop_subscription_if_exists(Chat.Repo, "internal_from_main")
      _ = LogicalReplicator.drop_slot_if_exists(main_repo, "internal_from_main")
      tables = Shapes.sync_tables()
      _ = LogicalReplicator.create_publication(main_repo, tables, "main_to_internal")

      # Create subscription on internal for main→internal
      # Use port from pg_opts since repo.config() may have compile-time port
      conn_string = Pg.build_connection_string(main_repo, port: main_port)

      # Slot first, so the subscription reuses it instead of creating one itself —
      # that would hang when both DBs share a cluster (host drive emulation)
      _ = LogicalReplicator.ensure_slot_on_source(main_repo, "internal_from_main")

      case LogicalReplicator.create_subscription(
             Chat.Repo,
             conn_string,
             "main_to_internal",
             "internal_from_main",
             copy_data: false,
             enabled: false
           ) do
        :ok ->
          _ = LogicalReplicator.enable_subscription(Chat.Repo, "internal_from_main")
          log("PG replication switched to main→internal", :info)

        {:error, reason} ->
          log("Failed to create internal_from_main subscription: #{inspect(reason)}", :error)
      end
    else
      _ ->
        log("PG replication not configured, skipping", :debug)
    end
  end

  defp disable_pg_replication(_state) do
    _ = LogicalReplicator.drop_subscription_if_exists(Chat.Repo, "internal_from_main")
    _ = LogicalReplicator.drop_slot_if_exists(Chat.Repo, "main_from_internal")
    log("PG replication cleaned up on internal (USB ejected)", :info)
  end

  # The single switch of CubDB queue, repo, upload writer and Electric to main.
  # Writes then mirror back to internal.
  defp switch_default_to_main(args) do
    device = args |> Keyword.get(:pg_opts, %{}) |> Map.get(:device)

    case Units.by_role(:main) do
      {:ok, unit} -> unit
      :error -> Unit.usb(device, :main)
    end
    |> Default.switch_to()

    Switching.mirror(Chat.Db.MainDb, Chat.Db.InternalDb)
  end
end
