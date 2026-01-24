defmodule Platform.Storage.InternalToMain.Copier do
  @moduledoc """
  Copies data from internal to main db
  """
  use GracefulGenServer
  use Toolbox.OriginLog

  alias Chat.Db.Copying
  alias Chat.Db.Switching
  alias Chat.Sync.DbBrokers
  alias Platform.Storage.Sync
  alias Platform.Tools.Postgres
  alias Platform.Tools.Postgres.LogicalReplicator
  alias Platform.Leds

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

        # Start local in-process sync after bootstrap copy completes
        source_repo = Chat.Repo

        target_repo =
          case pg_opts do
            nil -> nil
            opts -> Map.get(opts, :repo)
          end

        if is_nil(target_repo) do
          log("skipping local sync target_repo_present?=false", :debug)
        else
          Sync.set_active()

          _ =
            Sync.run_local_sync(
              source_repo: source_repo,
              target_repo: target_repo,
              schemas: Sync.schemas()
            )

          # After sync completes, set up logical replication (internal → main)
          setup_logical_replication(source_repo, target_repo)
        end

        Switching.set_default(main)
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
    |> Switching.set_default()

    DbBrokers.refresh()
  end

  # Private helper to set up logical replication after sync
  defp setup_logical_replication(source_repo, target_repo) do
    conn_string = Postgres.build_connection_string(source_repo)

    # Clean up stale slots from previous sessions before creating new ones
    _ = LogicalReplicator.drop_slot_if_exists(source_repo, "main_from_internal")

    with :ok <- LogicalReplicator.create_publication(source_repo, ["users"], "internal_to_main"),
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
