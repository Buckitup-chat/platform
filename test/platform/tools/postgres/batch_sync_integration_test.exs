defmodule Platform.Tools.Postgres.BatchSyncIntegrationTest do
  use ExUnit.Case, async: false

  alias Platform.Test.{InternalRepo, MainRepo, DatabaseHelper}
  alias Platform.Tools.Postgres.BatchSync
  alias Chat.Data.Schemas.User

  @moduletag :integration
  @moduletag :postgres

  setup do
    # Setup repos and sandbox for each test
    DatabaseHelper.setup_repos()
    DatabaseHelper.truncate_all_tables()

    on_exit(fn ->
      DatabaseHelper.cleanup_repos()
    end)

    :ok
  end

  describe "sync/1 - with real databases" do
    test "syncs missing rows from source to target" do
      # Insert users in internal (source)
      {:ok, _} = InternalRepo.insert(%User{pub_key: "pk1", name: "Alice"})
      {:ok, _} = InternalRepo.insert(%User{pub_key: "pk2", name: "Bob"})
      {:ok, _} = InternalRepo.insert(%User{pub_key: "pk3", name: "Charlie"})

      # Verify source has 3 users
      assert InternalRepo.aggregate(User, :count) == 3

      # Verify target is empty
      assert MainRepo.aggregate(User, :count) == 0

      # Sync from internal to main
      result = BatchSync.sync(
        source_repo: InternalRepo,
        target_repo: MainRepo,
        schemas: [:users]
      )

      # Verify sync succeeded
      assert {:ok, stats} = result
      assert stats[:users] == 3

      # Verify target now has 3 users
      assert MainRepo.aggregate(User, :count) == 3

      # Verify data integrity
      users = MainRepo.all(User) |> Enum.sort_by(& &1.pub_key)
      assert length(users) == 3
      assert Enum.at(users, 0).name == "Alice"
      assert Enum.at(users, 1).name == "Bob"
      assert Enum.at(users, 2).name == "Charlie"
    end

    test "preserves existing rows on target (CRDT-like behavior)" do
      # Insert users in both repos
      {:ok, _} = InternalRepo.insert(%User{pub_key: "pk1", name: "Alice"})
      {:ok, _} = InternalRepo.insert(%User{pub_key: "pk2", name: "Bob"})

      {:ok, _} = MainRepo.insert(%User{pub_key: "pk1", name: "Alice Original"})

      # Sync from internal to main
      result = BatchSync.sync(
        source_repo: InternalRepo,
        target_repo: MainRepo,
        schemas: [:users]
      )

      # Verify sync succeeded
      assert {:ok, stats} = result
      # Only pk2 should be copied (pk1 already exists)
      assert stats[:users] == 1

      # Verify target has 2 users
      assert MainRepo.aggregate(User, :count) == 2

      # Verify pk1 was NOT overwritten (CRDT-like behavior)
      user = MainRepo.get!(User, "pk1")
      assert user.name == "Alice Original"
    end

    test "handles empty source database" do
      # Insert users only in target
      {:ok, _} = MainRepo.insert(%User{pub_key: "pk1", name: "Alice"})

      # Verify source is empty
      assert InternalRepo.aggregate(User, :count) == 0

      # Sync from internal to main
      result = BatchSync.sync(
        source_repo: InternalRepo,
        target_repo: MainRepo,
        schemas: [:users]
      )

      # Verify sync succeeded with 0 rows copied
      assert {:ok, stats} = result
      assert stats[:users] == 0

      # Verify target still has 1 user
      assert MainRepo.aggregate(User, :count) == 1
    end

    test "handles empty target database" do
      # Insert users only in source
      {:ok, _} = InternalRepo.insert(%User{pub_key: "pk1", name: "Alice"})
      {:ok, _} = InternalRepo.insert(%User{pub_key: "pk2", name: "Bob"})

      # Verify target is empty
      assert MainRepo.aggregate(User, :count) == 0

      # Sync from internal to main
      result = BatchSync.sync(
        source_repo: InternalRepo,
        target_repo: MainRepo,
        schemas: [:users]
      )

      # Verify sync succeeded
      assert {:ok, stats} = result
      assert stats[:users] == 2

      # Verify target now has 2 users
      assert MainRepo.aggregate(User, :count) == 2
    end

    test "syncs in reverse direction (main to internal)" do
      # Insert users in main (source)
      {:ok, _} = MainRepo.insert(%User{pub_key: "pk1", name: "Alice"})
      {:ok, _} = MainRepo.insert(%User{pub_key: "pk2", name: "Bob"})

      # Verify internal is empty
      assert InternalRepo.aggregate(User, :count) == 0

      # Sync from main to internal (reverse direction)
      result = BatchSync.sync(
        source_repo: MainRepo,
        target_repo: InternalRepo,
        schemas: [:users]
      )

      # Verify sync succeeded
      assert {:ok, stats} = result
      assert stats[:users] == 2

      # Verify internal now has 2 users
      assert InternalRepo.aggregate(User, :count) == 2
    end

    test "handles partial sync (some rows already exist)" do
      # Insert 5 users in source
      {:ok, _} = InternalRepo.insert(%User{pub_key: "pk1", name: "Alice"})
      {:ok, _} = InternalRepo.insert(%User{pub_key: "pk2", name: "Bob"})
      {:ok, _} = InternalRepo.insert(%User{pub_key: "pk3", name: "Charlie"})
      {:ok, _} = InternalRepo.insert(%User{pub_key: "pk4", name: "David"})
      {:ok, _} = InternalRepo.insert(%User{pub_key: "pk5", name: "Eve"})

      # Insert 2 users in target (pk1 and pk3)
      {:ok, _} = MainRepo.insert(%User{pub_key: "pk1", name: "Alice"})
      {:ok, _} = MainRepo.insert(%User{pub_key: "pk3", name: "Charlie"})

      # Sync from internal to main
      result = BatchSync.sync(
        source_repo: InternalRepo,
        target_repo: MainRepo,
        schemas: [:users]
      )

      # Verify sync succeeded
      assert {:ok, stats} = result
      # Should copy 3 missing users (pk2, pk4, pk5)
      assert stats[:users] == 3

      # Verify target now has 5 users
      assert MainRepo.aggregate(User, :count) == 5
    end

    test "handles binary pub_key correctly" do
      # Insert user with binary pub_key
      binary_key = :crypto.strong_rand_bytes(32)
      {:ok, _} = InternalRepo.insert(%User{pub_key: binary_key, name: "Binary User"})

      # Sync from internal to main
      result = BatchSync.sync(
        source_repo: InternalRepo,
        target_repo: MainRepo,
        schemas: [:users]
      )

      # Verify sync succeeded
      assert {:ok, stats} = result
      assert stats[:users] == 1

      # Verify binary key was preserved
      user = MainRepo.get!(User, binary_key)
      assert user.pub_key == binary_key
      assert user.name == "Binary User"
    end

    test "returns statistics for sync operation" do
      # Insert 10 users in source
      for i <- 1..10 do
        {:ok, _} = InternalRepo.insert(%User{pub_key: "pk#{i}", name: "User #{i}"})
      end

      # Sync from internal to main
      result = BatchSync.sync(
        source_repo: InternalRepo,
        target_repo: MainRepo,
        schemas: [:users]
      )

      # Verify statistics
      assert {:ok, stats} = result
      assert is_map(stats)
      assert stats[:users] == 10
    end
  end
end
