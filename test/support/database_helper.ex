defmodule Platform.Test.DatabaseHelper do
  @moduledoc """
  Helper module for setting up and tearing down test databases.

  Provides functions to:
  - Create test databases (platform_test_internal, platform_test_main)
  - Run migrations on test databases
  - Clean up test databases
  - Manage database connections for integration tests
  """

  alias Platform.Test.{InternalRepo, MainRepo}

  @internal_db "platform_test_internal"
  @main_db "platform_test_main"

  @doc """
  Creates the test databases if they don't exist.

  This should be run once before the test suite starts.
  Call this from test_helper.exs or in a setup_all block.
  """
  def setup_databases do
    # Get connection params from config
    config = Application.get_env(:platform, InternalRepo)
    username = config[:username]
    password = config[:password]
    hostname = config[:hostname]
    port = config[:port]

    # Create databases using psql
    create_database(@internal_db, username, password, hostname, port)
    create_database(@main_db, username, password, hostname, port)

    # Run migrations on both databases
    migrate_database(@internal_db, username, password, hostname, port)
    migrate_database(@main_db, username, password, hostname, port)

    :ok
  end

  @doc """
  Drops the test databases.

  This should be run after the test suite completes.
  """
  def teardown_databases do
    config = Application.get_env(:platform, InternalRepo)
    username = config[:username]
    password = config[:password]
    hostname = config[:hostname]
    port = config[:port]

    drop_database(@internal_db, username, password, hostname, port)
    drop_database(@main_db, username, password, hostname, port)

    :ok
  end

  @doc """
  Starts both test repos and sets up SQL Sandbox for test isolation.

  Use this in test setup blocks:

      setup do
        DatabaseHelper.setup_repos()
        on_exit(fn -> DatabaseHelper.cleanup_repos() end)
        :ok
      end
  """
  def setup_repos do
    # Start repos if not already started
    start_repo(InternalRepo)
    start_repo(MainRepo)

    # Checkout sandbox connections
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(InternalRepo)
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(MainRepo)

    # Set sandbox mode to manual for explicit control
    Ecto.Adapters.SQL.Sandbox.mode(InternalRepo, {:shared, self()})
    Ecto.Adapters.SQL.Sandbox.mode(MainRepo, {:shared, self()})

    :ok
  end

  @doc """
  Cleans up repos after tests.
  """
  def cleanup_repos do
    # Sandbox will automatically rollback transactions
    :ok
  end

  @doc """
  Truncates all tables in both test databases.

  Useful for cleaning state between tests.
  """
  def truncate_all_tables do
    Ecto.Adapters.SQL.query!(InternalRepo, "TRUNCATE TABLE users RESTART IDENTITY CASCADE")
    Ecto.Adapters.SQL.query!(MainRepo, "TRUNCATE TABLE users RESTART IDENTITY CASCADE")
    :ok
  end

  # Private functions

  defp start_repo(repo) do
    case repo.start_link() do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
      error -> error
    end
  end

  defp create_database(db_name, username, password, hostname, port) do
    env = [
      {"PGPASSWORD", password}
    ]

    case System.cmd(
           "psql",
           [
             "-h", hostname,
             "-p", to_string(port),
             "-U", username,
             "-d", "postgres",
             "-c", "CREATE DATABASE #{db_name}"
           ],
           env: env,
           stderr_to_stdout: true
         ) do
      {_output, 0} ->
        IO.puts("✓ Created database: #{db_name}")
        :ok

      {output, _code} ->
        if String.contains?(output, "already exists") do
          IO.puts("✓ Database already exists: #{db_name}")
          :ok
        else
          IO.puts("✗ Failed to create database #{db_name}: #{output}")
          {:error, output}
        end
    end
  end

  defp drop_database(db_name, username, password, hostname, port) do
    env = [
      {"PGPASSWORD", password}
    ]

    case System.cmd(
           "psql",
           [
             "-h", hostname,
             "-p", to_string(port),
             "-U", username,
             "-d", "postgres",
             "-c", "DROP DATABASE IF EXISTS #{db_name}"
           ],
           env: env,
           stderr_to_stdout: true
         ) do
      {_output, 0} ->
        IO.puts("✓ Dropped database: #{db_name}")
        :ok

      {output, _code} ->
        IO.puts("✗ Failed to drop database #{db_name}: #{output}")
        {:error, output}
    end
  end

  defp migrate_database(db_name, username, password, hostname, port) do
    env = [
      {"PGPASSWORD", password}
    ]

    # Create users table schema
    sql = """
    CREATE TABLE IF NOT EXISTS users (
      pub_key bytea PRIMARY KEY,
      name text NOT NULL
    );
    """

    case System.cmd(
           "psql",
           [
             "-h", hostname,
             "-p", to_string(port),
             "-U", username,
             "-d", db_name,
             "-c", sql
           ],
           env: env,
           stderr_to_stdout: true
         ) do
      {_output, 0} ->
        IO.puts("✓ Migrated database: #{db_name}")
        :ok

      {output, _code} ->
        IO.puts("✗ Failed to migrate database #{db_name}: #{output}")
        {:error, output}
    end
  end
end
