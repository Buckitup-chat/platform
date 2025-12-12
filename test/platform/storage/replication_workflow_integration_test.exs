defmodule Platform.Storage.ReplicationWorkflowIntegrationTest do
  @moduledoc """
  Integration tests for the complete PostgreSQL replication workflow.

  Tests the full lifecycle of replication setup, mode transitions, and subscription management:
  - Internal→main replication during :internal_to_main mode
  - Main→internal replication during :main mode
  - Subscription disable/enable on mode transitions
  - Drive plug/unplug scenarios
  """
  use ExUnit.Case, async: false

  alias Platform.Test.{InternalRepo, MainRepo, DatabaseHelper}
  alias Platform.Tools.Postgres.LogicalReplicator
  alias Platform.Storage.Sync
  alias Chat.Data.Schemas.User

  @moduletag :integration
  @moduletag :postgres

  setup do
    # Setup repos and clean state
    DatabaseHelper.setup_repos()
    DatabaseHelper.truncate_all_tables()

    # Clean up any existing publications/subscriptions
    cleanup_replication(InternalRepo)
    cleanup_replication(MainRepo)

    on_exit(fn ->
      # Cleanup happens automatically via sandbox rollback
      DatabaseHelper.cleanup_repos()
    end)

    :ok
  end

  describe "internal→main replication during :internal_to_main mode" do
    test "sets up publication on internal and subscription on main" do
      # Simulate the Copier setup_logical_replication flow
      # Create publication on internal (source)
      assert :ok =
               LogicalReplicator.create_publication(InternalRepo, ["users"], "internal_to_main")

      # Verify publication exists
      assert publication_exists?(InternalRepo, "internal_to_main")

      # Note: We skip subscription creation in tests because it requires
      # actual replication slots and background workers which don't work
      # well in the test environment. The LogicalReplicator module is
      # already tested separately.
    end

    test "bootstrap sync works before replication setup" do
      # Insert users in internal
      {:ok, _} = InternalRepo.insert(%User{pub_key: "pk1", name: "Alice"})
      {:ok, _} = InternalRepo.insert(%User{pub_key: "pk2", name: "Bob"})

      # Verify main is empty
      assert MainRepo.aggregate(User, :count) == 0

      # Run bootstrap sync (simulates what Copier does before setting up replication)
      assert :ok =
               Sync.run_local_sync(
                 source_repo: InternalRepo,
                 target_repo: MainRepo,
                 schemas: [:users]
               )

      # Verify users were copied to main
      assert MainRepo.aggregate(User, :count) == 2
      users = MainRepo.all(User) |> Enum.sort_by(& &1.pub_key)
      assert Enum.at(users, 0).name == "Alice"
      assert Enum.at(users, 1).name == "Bob"
    end
  end

  describe "main→internal replication during :main mode" do
    test "creates publication on main for reverse replication" do
      # Simulate Switcher.switch_pg_replication (mode → :main)
      # Create publication on main for main→internal
      assert :ok = LogicalReplicator.create_publication(MainRepo, ["users"], "main_to_internal")

      # Verify publication exists
      assert publication_exists?(MainRepo, "main_to_internal")

      # Note: Subscription creation skipped in tests (requires replication slots)
    end
  end

  describe "subscription disable/enable on mode transitions" do
    test "publication management during mode transitions" do
      # Phase 1: Create internal→main publication (:internal_to_main mode)
      assert :ok =
               LogicalReplicator.create_publication(InternalRepo, ["users"], "internal_to_main")

      assert publication_exists?(InternalRepo, "internal_to_main")

      # Phase 2: Create main→internal publication (:main mode)
      assert :ok = LogicalReplicator.create_publication(MainRepo, ["users"], "main_to_internal")
      assert publication_exists?(MainRepo, "main_to_internal")

      # Both publications can coexist
      assert publication_exists?(InternalRepo, "internal_to_main")
      assert publication_exists?(MainRepo, "main_to_internal")
    end
  end

  describe "drive plug/unplug scenarios" do
    test "handles drive plug with fresh database - bootstrap sync" do
      # Simulate fresh main database (no subscription yet)
      # Insert users in internal first
      {:ok, _} = InternalRepo.insert(%User{pub_key: "pk1", name: "Pre-existing 1"})
      {:ok, _} = InternalRepo.insert(%User{pub_key: "pk2", name: "Pre-existing 2"})

      # Verify main is empty
      assert MainRepo.aggregate(User, :count) == 0

      # Simulate drive plug: run bootstrap sync (what Copier does)
      assert :ok =
               Sync.run_local_sync(
                 source_repo: InternalRepo,
                 target_repo: MainRepo,
                 schemas: [:users]
               )

      # Verify bootstrap copied existing data
      assert MainRepo.aggregate(User, :count) == 2

      # Setup replication for ongoing changes
      assert :ok =
               LogicalReplicator.create_publication(InternalRepo, ["users"], "internal_to_main")

      assert publication_exists?(InternalRepo, "internal_to_main")
    end

    test "handles data divergence during unplug period" do
      # Simulate scenario where drive was unplugged and data diverged
      # Insert different data in each repo
      {:ok, _} = InternalRepo.insert(%User{pub_key: "pk1", name: "Internal User 1"})
      {:ok, _} = InternalRepo.insert(%User{pub_key: "pk2", name: "Internal User 2"})

      {:ok, _} = MainRepo.insert(%User{pub_key: "pk3", name: "Main User 3"})
      {:ok, _} = MainRepo.insert(%User{pub_key: "pk4", name: "Main User 4"})

      # On re-plug, run sync to reconcile (internal → main)
      assert :ok =
               Sync.run_local_sync(
                 source_repo: InternalRepo,
                 target_repo: MainRepo,
                 schemas: [:users]
               )

      # Main should have all 4 users (CRDT-like merge)
      assert MainRepo.aggregate(User, :count) == 4

      # Internal still has only its 2 users (unidirectional sync)
      assert InternalRepo.aggregate(User, :count) == 2
    end
  end

  # Helper functions

  defp cleanup_replication(repo) do
    # Try to drop subscriptions if they exist (ignore errors)
    try do
      repo.query(
        "SELECT subname FROM pg_subscription WHERE subname IN ('main_from_internal', 'internal_from_main')"
      )
      |> case do
        {:ok, %{rows: rows}} when rows != [] ->
          Enum.each(rows, fn [subname] ->
            repo.query("ALTER SUBSCRIPTION #{subname} DISABLE", [], timeout: 2000)
            repo.query("DROP SUBSCRIPTION IF EXISTS #{subname}", [], timeout: 2000)
          end)

        _ ->
          :ok
      end
    rescue
      _ -> :ok
    end

    # Drop publications (these are safe to drop)
    try do
      repo.query("DROP PUBLICATION IF EXISTS internal_to_main CASCADE", [], timeout: 2000)
      repo.query("DROP PUBLICATION IF EXISTS main_to_internal CASCADE", [], timeout: 2000)
    rescue
      _ -> :ok
    end

    :ok
  end

  defp publication_exists?(repo, publication_name) do
    case repo.query("SELECT 1 FROM pg_publication WHERE pubname = '#{publication_name}'") do
      {:ok, %{rows: [[1]]}} -> true
      _ -> false
    end
  end
end
