defmodule Platform.Storage.ReplicationWorkflowIntegrationTest do
  @moduledoc """
  Integration tests for the complete PostgreSQL replication workflow.

  Bootstrap sync (`Platform.Storage.Sync.run_local_sync/1`) on drive plug and after divergence.

  Publication / slot / subscription behaviour of `Chat.Storage.Pg.LogicalReplicator` is
  tested in chat (`Chat.Storage.Pg.LogicalReplicatorIntegrationTest`).
  """
  use ExUnit.Case, async: false

  alias Platform.Storage.Sync
  alias Platform.Test.{DatabaseHelper, InternalRepo, MainRepo, User}

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

  describe "bootstrap sync during :internal_to_main mode" do
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
                 schemas: [User]
               )

      # Verify users were copied to main
      assert MainRepo.aggregate(User, :count) == 2
      users = MainRepo.all(User) |> Enum.sort_by(& &1.pub_key)
      assert Enum.at(users, 0).name == "Alice"
      assert Enum.at(users, 1).name == "Bob"
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
                 schemas: [User]
               )

      # Verify bootstrap copied existing data
      assert MainRepo.aggregate(User, :count) == 2
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
                 schemas: [User]
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
end
