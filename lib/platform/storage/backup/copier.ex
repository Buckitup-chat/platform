defmodule Platform.Storage.Backup.Copier do
  @moduledoc """
  Syncs data between backup and current DB
  """
  use GracefulGenServer
  use Toolbox.OriginLog

  alias Chat.Db
  alias Chat.Db.{Common, Copying, Switching}
  alias Chat.Ordering
  alias Chat.Sync.DbBrokers

  alias Platform.Leds
  alias Platform.Storage.Stopper
  alias Platform.Storage.Sync
  alias Platform.Tools.Postgres
  alias Platform.Tools.Postgres.BatchSync
  alias Platform.Tools.Postgres.LogicalReplicator

  @impl true
  def on_init(opts) do
    %{
      task_in: opts |> Keyword.fetch!(:tasks_name),
      continuous?: opts |> Keyword.fetch!(:continuous?),
      task_ref: nil,
      device: opts[:device],
      backup_repo: opts[:backup_repo]
    }
    |> tap(fn _ -> send(self(), :start) end)
  end

  @impl true
  def on_msg(
        :start,
        %{task_in: tasks_name, continuous?: continuous?, backup_repo: backup_repo} = state
      ) do
    log("syncing", :info)

    internal = Chat.Db.InternalDb
    main = Chat.Db.MainDb
    backup = Chat.Db.BackupDb

    set_db_flag(backup: true)

    %{ref: ref} =
      tasks_name
      |> Task.Supervisor.async_nolink(fn ->
        Leds.blink_read()
        Copying.await_copied(Chat.Db.BackupDb, Db.db())
        Ordering.reset()
        Leds.blink_write()
        Copying.await_copied(Db.db(), Chat.Db.BackupDb)

        sync_pg(backup_repo)

        if continuous? do
          Process.sleep(1_000)
          Switching.mirror(main, [internal, backup])
          setup_pg_replication(backup_repo)
          Process.sleep(3_000)
        end

        DbBrokers.refresh()
        Leds.blink_done()
      end)

    {:noreply, %{state | task_ref: ref}}
  end

  def on_msg({ref, _}, %{task_ref: ref} = state) do
    Process.demonitor(ref, [:flush])
    send(self(), :copied)
    {:noreply, state}
  end

  def on_msg({_ref, _result}, state) do
    {:noreply, state}
  end

  def on_msg({:DOWN, _ref, :process, _pid, reason}, state) do
    log("task DOWN: #{inspect(reason)}", :error)
    {:noreply, state}
  end

  def on_msg(:copied, %{continuous?: continuous?, device: device} = state) do
    set_db_flag(backup: false)

    unless continuous? do
      Stopper.start_link(wait: 100, device: device)
    end

    log("synced", :info)
    {:noreply, state}
  end

  @impl true
  def on_exit(_reason, state) do
    internal = Chat.Db.InternalDb
    main = Chat.Db.MainDb

    set_db_flag(backup: false)
    Leds.blink_done()
    cleanup_pg_replication(state[:backup_repo])
    Switching.mirror(main, internal)
    Ordering.reset()
    DbBrokers.refresh()
  end

  defp sync_pg(nil), do: :ok

  defp sync_pg(backup_repo) do
    schemas = Sync.schemas()

    [{backup_repo, Chat.Repo, "restore"}, {Chat.Repo, backup_repo, "backup"}]
    |> Enum.each(fn {source, target, label} ->
      log("PG #{label} sync", :info)

      case BatchSync.sync(source_repo: source, target_repo: target, schemas: schemas) do
        {:ok, _} -> log("PG #{label} complete", :info)
        {:partial, _, failures} -> log("PG #{label} partial: #{inspect(Map.keys(failures))}", :warning)
        {:error, reason} -> log("PG #{label} failed: #{inspect(reason)}", :error)
      end
    end)
  rescue
    e -> log("PG sync error: #{inspect(e)}", :error)
  end

  defp setup_pg_replication(nil), do: :ok

  defp setup_pg_replication(backup_repo) do
    source_repo = Chat.Repo
    conn_string = Postgres.build_connection_string(source_repo)

    _ = LogicalReplicator.drop_slot_if_exists(source_repo, "backup_from_internal")
    tables = Chat.Data.Shapes.sync_tables()

    with :ok <- LogicalReplicator.create_publication(source_repo, tables, "internal_to_backup"),
         :ok <-
           LogicalReplicator.create_subscription(
             backup_repo,
             conn_string,
             "internal_to_backup",
             "backup_from_internal",
             copy_data: false,
             enabled: false
           ) do
      _ = LogicalReplicator.ensure_slot_on_source(source_repo, "backup_from_internal")
      _ = LogicalReplicator.enable_subscription(backup_repo, "backup_from_internal")
      log("PG backup replication started", :info)
    else
      {:error, reason} ->
        log("PG backup replication failed: #{inspect(reason)}", :error)
    end
  rescue
    e -> log("PG backup replication error: #{inspect(e)}", :error)
  end

  defp cleanup_pg_replication(nil), do: :ok

  defp cleanup_pg_replication(backup_repo) do
    _ = LogicalReplicator.drop_subscription_if_exists(backup_repo, "backup_from_internal")
    _ = LogicalReplicator.drop_slot_if_exists(Chat.Repo, "backup_from_internal")
    log("PG backup replication cleaned up", :info)
  rescue
    e -> log("PG replication cleanup error: #{inspect(e)}", :error)
  end

  defp set_db_flag(flags) do
    Common.get_chat_db_env(:flags)
    |> Keyword.merge(flags)
    |> then(&Common.put_chat_db_env(:flags, &1))
  end
end
