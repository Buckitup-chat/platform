defmodule Platform.Storage.InternalToMain.Copier do
  @moduledoc """
  Copies data from internal to main db
  """
  use GracefulGenServer
  use Toolbox.OriginLog

  alias Chat.Data.Shapes
  alias Chat.Db.Copying
  alias Chat.Db.Switching
  alias Chat.Sync.DbBrokers
  alias Platform.Leds
  alias Platform.Storage.Sync
  alias Platform.Tools.Postgres
  alias Platform.Tools.Postgres.LogicalReplicator

  @impl true
  def on_init(opts) do
    task_supervisor = opts |> Keyword.fetch!(:task_in)
    next_opts = opts |> Keyword.fetch!(:next)
    next_supervisor = next_opts |> Keyword.fetch!(:under)
    next_specs = next_opts |> Keyword.fetch!(:run)
    pg_opts = Keyword.get(opts, :pg_opts)

    send(self(), :start)

    %{task_in: task_supervisor, task: nil, next: {next_specs, next_supervisor}, pg_opts: pg_opts}
  end

  @impl true
  def on_msg(:start, %{task_in: task_supervisor} = state) do
    log("copying internal to main", :warning)

    internal = Chat.Db.InternalDb
    main = Chat.Db.MainDb
    pg_opts = Map.get(state, :pg_opts)

    Leds.blink_write()

    task =
      Task.Supervisor.async_nolink(task_supervisor, fn ->
        Switching.mirror(internal, main)
        Copying.await_copied(internal, main)

        sync_pg_to_main(pg_opts)

        device = Map.get(pg_opts, :device)
        Switching.set_default(main, drive_id: device)
        Process.sleep(1_000)
        Switching.mirror(main, internal)
        DbBrokers.refresh()
      end)

    {:noreply, %{state | task: task}}
  end

  def on_msg({ref, _}, %{task: %Task{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])

    send(self(), :copied)
    {:noreply, state}
  end

  def on_msg(:copied, %{next: {next_specs, next_supervisor}} = state) do
    log("Data moved to external storage", :info)
    Sync.set_done()
    Leds.blink_done()

    Platform.start_next_stage(next_supervisor, next_specs)

    {:noreply, state}
  end

  @impl true
  def on_exit(reason, _state) do
    log("copier cleanup #{inspect(reason)}", :warning)

    Leds.blink_done()

    Chat.Db.InternalDb
    |> Switching.set_default(drive_id: :internal)

    DbBrokers.refresh()
  end

  # Local in-process PG sync after bootstrap copy completes
  defp sync_pg_to_main(pg_opts) do
    case pg_opts && Map.get(pg_opts, :repo) do
      nil -> log("skipping local sync target_repo_present?=false", :debug)
      target_repo -> sync_and_replicate_pg(Chat.Repo, target_repo)
    end
  end

  defp sync_and_replicate_pg(source_repo, target_repo) do
    Sync.set_active()

    [source_repo: source_repo, target_repo: target_repo, schemas: Sync.schemas()]
    |> Sync.run_local_sync()
    |> case do
      :ok ->
        setup_logical_replication(source_repo, target_repo)
        broadcast_pg_diff_copied()

      {:partial, failures} ->
        # Some tables were skipped (constraint/data errors). The tables that did
        # sync are on the drive, and logical replication plus the next attach heal
        # the rest — so continue, but the status stays :partial (not :done).
        log("local sync incomplete, skipped tables=#{inspect(Map.keys(failures))}", :error)
        setup_logical_replication(source_repo, target_repo)
        broadcast_pg_diff_copied()

      {:error, reason} ->
        # Connection/infra failure: do not set up replication against a target we
        # could not sync. Status stays {:error, _} and is not overwritten by :done.
        log("local sync aborted, skipping replication setup reason=#{inspect(reason)}", :error)
    end
  end

  defp broadcast_pg_diff_copied do
    Phoenix.PubSub.broadcast(Chat.PubSub, "chunk_pipeline", {:chunk_pipeline, :pg_diff_copied})
  end

  # Private helper to set up logical replication after sync
  defp setup_logical_replication(source_repo, target_repo) do
    conn_string = Postgres.build_connection_string(source_repo)

    # Clean up stale slots from previous sessions before creating new ones
    _ = LogicalReplicator.drop_slot_if_exists(source_repo, "main_from_internal")

    tables = Shapes.sync_tables()

    with :ok <- LogicalReplicator.create_publication(source_repo, tables, "internal_to_main"),
         :ok <-
           LogicalReplicator.create_subscription(
             target_repo,
             conn_string,
             "internal_to_main",
             "main_from_internal",
             copy_data: false,
             # Create disabled, enable after ensuring slot
             enabled: false
           ) do
      # Ensure slot exists on source before enabling subscription
      _ = LogicalReplicator.ensure_slot_on_source(source_repo, "main_from_internal")
      _ = LogicalReplicator.enable_subscription(target_repo, "main_from_internal")
      log("logical replication setup complete", :info)
    else
      {:error, reason} ->
        log("failed to setup replication: #{inspect(reason)}", :error)
    end
  end
end
