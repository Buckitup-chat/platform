defmodule Platform.Tools.Postgres.LogicalReplicatorTest do
  use ExUnit.Case, async: true

  alias Platform.Tools.Postgres.LogicalReplicator

  @moduletag :capture_log

  # Mock Ecto.Repo for testing SQL execution
  defmodule RepoMock do
    def query(sql) do
      test_pid = Process.get(:test_pid)
      send(test_pid, {:repo_query, sql})

      # Return different responses based on query type
      case Process.get(:query_result, :ok) do
        :ok ->
          {:ok, %{rows: [], num_rows: 0}}

        :error ->
          {:error, :query_failed}

        {:lag, bytes} ->
          {:ok, %{rows: [[bytes]], num_rows: 1}}

        :subscription_not_found ->
          {:ok, %{rows: [], num_rows: 0}}
      end
    end
  end

  setup do
    test_pid = self()
    Process.put(:test_pid, test_pid)
    Process.put(:query_result, :ok)
    :ok
  end

  describe "create_publication/3" do
    test "creates publication with specified tables" do
      result = LogicalReplicator.create_publication(
        RepoMock,
        ["users", "messages"],
        "my_publication"
      )

      assert :ok = result
      assert_received {:repo_query, sql}
      assert sql =~ "CREATE PUBLICATION my_publication"
      assert sql =~ "FOR TABLE users, messages"
      assert sql =~ "IF NOT EXISTS"
    end

    test "creates publication with single table" do
      result = LogicalReplicator.create_publication(
        RepoMock,
        ["users"],
        "users_pub"
      )

      assert :ok = result
      assert_received {:repo_query, sql}
      assert sql =~ "FOR TABLE users"
    end

    test "returns error when query fails" do
      Process.put(:query_result, :error)

      result = LogicalReplicator.create_publication(
        RepoMock,
        ["users"],
        "my_publication"
      )

      assert {:error, :query_failed} = result
    end

    test "uses DO $$ block for idempotency" do
      LogicalReplicator.create_publication(
        RepoMock,
        ["users"],
        "my_publication"
      )

      assert_received {:repo_query, sql}
      assert sql =~ "DO $$"
      assert sql =~ "END $$"
    end
  end

  describe "create_subscription/5" do
    test "creates subscription with default options" do
      result = LogicalReplicator.create_subscription(
        RepoMock,
        "host=localhost port=5432 dbname=chat user=replicator password=secret",
        "source_publication",
        "my_subscription"
      )

      assert :ok = result
      assert_received {:repo_query, sql}
      assert sql =~ "CREATE SUBSCRIPTION my_subscription"
      assert sql =~ "CONNECTION 'host=localhost port=5432 dbname=chat user=replicator password=secret'"
      assert sql =~ "PUBLICATION source_publication"
      assert sql =~ "copy_data = false"
      assert sql =~ "enabled = true"
    end

    test "creates subscription with copy_data enabled" do
      result = LogicalReplicator.create_subscription(
        RepoMock,
        "host=localhost port=5432 dbname=chat user=replicator",
        "source_publication",
        "my_subscription",
        copy_data: true
      )

      assert :ok = result
      assert_received {:repo_query, sql}
      assert sql =~ "copy_data = true"
    end

    test "creates subscription with enabled false" do
      result = LogicalReplicator.create_subscription(
        RepoMock,
        "host=localhost port=5432 dbname=chat user=replicator",
        "source_publication",
        "my_subscription",
        enabled: false
      )

      assert :ok = result
      assert_received {:repo_query, sql}
      assert sql =~ "enabled = false"
    end

    test "creates subscription with both options" do
      result = LogicalReplicator.create_subscription(
        RepoMock,
        "host=localhost port=5432 dbname=chat user=replicator",
        "source_publication",
        "my_subscription",
        copy_data: true,
        enabled: false
      )

      assert :ok = result
      assert_received {:repo_query, sql}
      assert sql =~ "copy_data = true"
      assert sql =~ "enabled = false"
    end

    test "returns error when query fails" do
      Process.put(:query_result, :error)

      result = LogicalReplicator.create_subscription(
        RepoMock,
        "host=localhost port=5432 dbname=chat user=replicator",
        "source_publication",
        "my_subscription"
      )

      assert {:error, :query_failed} = result
    end

    test "uses DO $$ block for idempotency" do
      LogicalReplicator.create_subscription(
        RepoMock,
        "host=localhost port=5432 dbname=chat user=replicator",
        "source_publication",
        "my_subscription"
      )

      assert_received {:repo_query, sql}
      assert sql =~ "DO $$"
      assert sql =~ "IF NOT EXISTS"
      assert sql =~ "END $$"
    end
  end

  describe "enable_subscription/2" do
    test "enables subscription" do
      result = LogicalReplicator.enable_subscription(
        RepoMock,
        "my_subscription"
      )

      assert :ok = result
      assert_received {:repo_query, sql}
      assert sql =~ "ALTER SUBSCRIPTION my_subscription ENABLE"
    end

    test "returns error when query fails" do
      Process.put(:query_result, :error)

      result = LogicalReplicator.enable_subscription(
        RepoMock,
        "my_subscription"
      )

      assert {:error, :query_failed} = result
    end
  end

  describe "disable_subscription/2" do
    test "disables subscription" do
      result = LogicalReplicator.disable_subscription(
        RepoMock,
        "my_subscription"
      )

      assert :ok = result
      assert_received {:repo_query, sql}
      assert sql =~ "ALTER SUBSCRIPTION my_subscription DISABLE"
    end

    test "returns error when query fails" do
      Process.put(:query_result, :error)

      result = LogicalReplicator.disable_subscription(
        RepoMock,
        "my_subscription"
      )

      assert {:error, :query_failed} = result
    end
  end

  describe "check_replication_lag/2" do
    test "returns lag in bytes when subscription exists" do
      Process.put(:query_result, {:lag, 1024})

      result = LogicalReplicator.check_replication_lag(
        RepoMock,
        "my_subscription"
      )

      assert {:ok, 1024} = result
      assert_received {:repo_query, sql}
      assert sql =~ "pg_stat_subscription"
      assert sql =~ "subname = 'my_subscription'"
    end

    test "returns zero lag when no lag" do
      Process.put(:query_result, {:lag, 0})

      result = LogicalReplicator.check_replication_lag(
        RepoMock,
        "my_subscription"
      )

      assert {:ok, 0} = result
    end

    test "returns error when subscription not found" do
      Process.put(:query_result, :subscription_not_found)

      result = LogicalReplicator.check_replication_lag(
        RepoMock,
        "my_subscription"
      )

      assert {:error, :subscription_not_found} = result
    end

    test "returns error when query fails" do
      Process.put(:query_result, :error)

      result = LogicalReplicator.check_replication_lag(
        RepoMock,
        "my_subscription"
      )

      assert {:error, :query_failed} = result
    end

    test "uses pg_wal_lsn_diff for lag calculation" do
      Process.put(:query_result, {:lag, 2048})

      LogicalReplicator.check_replication_lag(
        RepoMock,
        "my_subscription"
      )

      assert_received {:repo_query, sql}
      assert sql =~ "pg_wal_lsn_diff(sent_lsn, write_lsn)"
      assert sql =~ "pg_wal_lsn_diff(write_lsn, flush_lsn)"
      assert sql =~ "pg_wal_lsn_diff(flush_lsn, replay_lsn)"
      assert sql =~ "COALESCE"
    end

    test "truncates float lag to integer" do
      Process.put(:query_result, {:lag, 1024.5})

      result = LogicalReplicator.check_replication_lag(
        RepoMock,
        "my_subscription"
      )

      assert {:ok, 1024} = result
    end
  end
end
