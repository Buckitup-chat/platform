defmodule Platform.Storage.SyncIntegrationTest do
  use ExUnit.Case, async: false

  alias Chat.Data.Shapes
  alias Platform.Storage.Sync
  alias Platform.Test.{DatabaseHelper, InternalRepo, MainRepo, User}

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
          schemas: [User]
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
          schemas: [User]
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
          schemas: [User]
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
          schemas: [User]
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
          schemas: [User]
        )

      # Should return error due to missing source_repo
      assert {:error, _reason} = result
    end

    test "returns error when target repo is missing" do
      result =
        Sync.run_local_sync(
          source_repo: InternalRepo,
          schemas: [User]
        )

      # Should return error due to missing target_repo
      assert {:error, _reason} = result
    end

    test "uses configured schemas when not specified" do
      # Test DBs only have the `users` table, so point the configured schemas at it
      original = Application.get_env(:platform, Sync)
      Application.put_env(:platform, Sync, schemas: [User])

      on_exit(fn ->
        if original,
          do: Application.put_env(:platform, Sync, original),
          else: Application.delete_env(:platform, Sync)
      end)

      {:ok, _} = InternalRepo.insert(%User{pub_key: "pk1", name: "Alice"})

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
          schemas: [User]
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
          schemas: [User]
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

  describe "schemas/1" do
    @tag :no_db
    test "returns chat's sync schemas when not configured" do
      assert Sync.schemas() == Shapes.sync_schemas()
    end

    @tag :no_db
    test "returns the given default when not configured" do
      assert Sync.schemas(default: [User]) == [User]
    end

    @tag :no_db
    test "returns configured schemas even when default is provided" do
      original = Application.get_env(:platform, Sync)
      Application.put_env(:platform, Sync, schemas: [User])

      on_exit(fn ->
        if original,
          do: Application.put_env(:platform, Sync, original),
          else: Application.delete_env(:platform, Sync)
      end)

      assert Sync.schemas(default: [:users, :messages]) == [User]
    end
  end
end
