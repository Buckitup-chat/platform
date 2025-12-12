defmodule Platform.Storage.SyncIntegrationTest do
  use ExUnit.Case, async: false

  alias Platform.Test.{InternalRepo, MainRepo, DatabaseHelper}
  alias Platform.Storage.Sync
  alias Chat.Data.Schemas.User

  @moduletag :integration
  @moduletag :postgres

  setup tags do
    # Reset persistent_term status for all tests
    :persistent_term.erase({Sync, :status})

    # Only setup database for tests that need it
    unless tags[:no_db] do
      DatabaseHelper.setup_repos()
      DatabaseHelper.truncate_all_tables()

      on_exit(fn ->
        DatabaseHelper.cleanup_repos()
      end)
    end

    on_exit(fn ->
      :persistent_term.erase({Sync, :status})
    end)

    :ok
  end

  describe "run_local_sync/1" do
    test "performs full sync flow with :users schema" do
      # Insert users in source
      {:ok, _} = InternalRepo.insert(%User{pub_key: "pk1", name: "Alice"})
      {:ok, _} = InternalRepo.insert(%User{pub_key: "pk2", name: "Bob"})
      {:ok, _} = InternalRepo.insert(%User{pub_key: "pk3", name: "Charlie"})

      # Run sync
      result =
        Sync.run_local_sync(
          source_repo: InternalRepo,
          target_repo: MainRepo,
          schemas: [:users]
        )

      # Verify sync succeeded
      assert :ok = result

      # Verify target has all users
      assert MainRepo.aggregate(User, :count) == 3
    end

    test "handles sync with diverged data" do
      # Insert different users in each repo
      {:ok, _} = InternalRepo.insert(%User{pub_key: "pk1", name: "Alice"})
      {:ok, _} = InternalRepo.insert(%User{pub_key: "pk2", name: "Bob"})

      {:ok, _} = MainRepo.insert(%User{pub_key: "pk3", name: "Charlie"})
      {:ok, _} = MainRepo.insert(%User{pub_key: "pk4", name: "David"})

      # Run sync (internal -> main)
      result =
        Sync.run_local_sync(
          source_repo: InternalRepo,
          target_repo: MainRepo,
          schemas: [:users]
        )

      # Verify sync succeeded
      assert :ok = result

      # Verify target has users from both repos
      # Main should have: pk1, pk2 (from internal) + pk3, pk4 (existing)
      assert MainRepo.aggregate(User, :count) == 4

      # Verify internal still has only its original users
      assert InternalRepo.aggregate(User, :count) == 2
    end

    test "handles sync with empty target" do
      # Insert users only in source
      {:ok, _} = InternalRepo.insert(%User{pub_key: "pk1", name: "Alice"})
      {:ok, _} = InternalRepo.insert(%User{pub_key: "pk2", name: "Bob"})

      # Verify target is empty
      assert MainRepo.aggregate(User, :count) == 0

      # Run sync
      result =
        Sync.run_local_sync(
          source_repo: InternalRepo,
          target_repo: MainRepo,
          schemas: [:users]
        )

      # Verify sync succeeded
      assert :ok = result

      # Verify target now has users
      assert MainRepo.aggregate(User, :count) == 2
    end

    test "handles error and updates status" do
      # Try to sync with invalid repo (will cause error)
      result =
        Sync.run_local_sync(
          source_repo: InvalidRepo,
          target_repo: MainRepo,
          schemas: [:users]
        )

      # Verify error was returned
      assert {:error, _reason} = result

      # Verify status was updated to error
      status = Sync.status()
      assert {:error, _} = status.state
    end

    test "returns error when source repo is missing" do
      result =
        Sync.run_local_sync(
          target_repo: MainRepo,
          schemas: [:users]
        )

      # Should return error due to missing source_repo
      assert {:error, _reason} = result
    end

    test "returns error when target repo is missing" do
      result =
        Sync.run_local_sync(
          source_repo: InternalRepo,
          schemas: [:users]
        )

      # Should return error due to missing target_repo
      assert {:error, _reason} = result
    end

    test "uses default schemas when not specified" do
      # Insert users in source
      {:ok, _} = InternalRepo.insert(%User{pub_key: "pk1", name: "Alice"})

      # Run sync without specifying schemas (should default to [:users])
      result =
        Sync.run_local_sync(
          source_repo: InternalRepo,
          target_repo: MainRepo
        )

      # Verify sync succeeded
      assert :ok = result

      # Verify user was synced
      assert MainRepo.aggregate(User, :count) == 1
    end

    test "handles large dataset sync" do
      # Insert 100 users in source
      for i <- 1..100 do
        {:ok, _} = InternalRepo.insert(%User{pub_key: "pk#{i}", name: "User #{i}"})
      end

      # Run sync
      result =
        Sync.run_local_sync(
          source_repo: InternalRepo,
          target_repo: MainRepo,
          schemas: [:users]
        )

      # Verify sync succeeded
      assert :ok = result

      # Verify all users were synced
      assert MainRepo.aggregate(User, :count) == 100
    end

    test "handles sync with no missing rows" do
      # Insert same users in both repos
      {:ok, _} = InternalRepo.insert(%User{pub_key: "pk1", name: "Alice"})
      {:ok, _} = MainRepo.insert(%User{pub_key: "pk1", name: "Alice"})

      # Run sync
      result =
        Sync.run_local_sync(
          source_repo: InternalRepo,
          target_repo: MainRepo,
          schemas: [:users]
        )

      # Verify sync succeeded (even with 0 rows copied)
      assert :ok = result

      # Verify counts remain the same
      assert InternalRepo.aggregate(User, :count) == 1
      assert MainRepo.aggregate(User, :count) == 1
    end
  end

  describe "status/0" do
    @tag :no_db
    test "returns inactive status initially" do
      status = Sync.status()
      assert status.state == :inactive
    end

    @tag :no_db
    test "returns active status when set" do
      Sync.set_active()
      status = Sync.status()
      assert status.state == :active
    end

    @tag :no_db
    test "returns done status when set" do
      Sync.set_done()
      status = Sync.status()
      assert status.state == :done
    end

    @tag :no_db
    test "returns error status when set" do
      Sync.set_error(:test_error)
      status = Sync.status()
      assert status.state == {:error, :test_error}
    end
  end

  describe "enabled?/0" do
    @tag :no_db
    test "returns true by default" do
      assert Sync.enabled?() == true
    end
  end

  describe "schemas/1" do
    @tag :no_db
    test "returns default schemas" do
      schemas = Sync.schemas()
      assert schemas == [:users]
    end

    @tag :no_db
    test "returns configured schemas even when default is provided" do
      # Config has schemas: [:users], so it should return that
      # even when a different default is provided
      schemas = Sync.schemas(default: [:users, :messages])
      assert schemas == [:users]
    end
  end
end
