defmodule Platform.Test.DatabaseHelper do
  @moduledoc """
  Helper module for setting up and tearing down test databases.

  Provides functions to:
  - Create test databases (platform_test_internal, platform_test_main)
  - Run migrations on test databases
  - Clean up test databases
  - Manage database connections for integration tests
  """

  alias Ecto.Adapters.SQL
  alias Ecto.Adapters.SQL.Sandbox
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

    drop_drive_databases()

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
    drop_drive_databases()

    :ok
  end

  @doc """
  Drops the per-drive databases that host drive emulation creates
  (`<Chat.Repo database>_<device>`), so each run starts from blank drives.

  Drive scenarios set up logical replication between those databases and
  `Chat.Repo`'s one. Slots are cluster-wide and pin WAL, so subscriptions and
  slots of all these databases go first.
  """
  def drop_drive_databases do
    config = Application.get_env(:platform, InternalRepo)
    chat_db = Application.get_env(:chat, Chat.Repo)[:database]

    "SELECT d.datname || ' ' || s.subname FROM pg_subscription s
       JOIN pg_database d ON d.oid = s.subdbid WHERE starts_with(d.datname, '#{chat_db}')"
    |> psql_rows(config)
    |> Enum.each(fn row ->
      [db, sub] = String.split(row)

      ["DISABLE", "SET (slot_name = NONE)"]
      |> Enum.each(&psql_rows("ALTER SUBSCRIPTION #{sub} #{&1}", config, db))

      psql_rows("DROP SUBSCRIPTION #{sub}", config, db)
    end)

    # Electric (running on Chat.Repo's database) manages its own slot
    slots =
      "starts_with(database, '#{chat_db}') AND NOT starts_with(slot_name, 'electric_')"

    "SELECT pg_terminate_backend(active_pid) FROM pg_replication_slots WHERE active AND #{slots}"
    |> psql_rows(config)

    "SELECT slot_name FROM pg_replication_slots WHERE #{slots}"
    |> psql_rows(config)
    |> Enum.each(&psql_rows("SELECT pg_drop_replication_slot('#{&1}')", config))

    "SELECT datname FROM pg_database WHERE starts_with(datname, '#{chat_db}_sd')"
    |> psql_rows(config)
    |> Enum.each(&psql_rows("DROP DATABASE IF EXISTS #{&1} WITH (FORCE)", config))
  end

  defp psql_rows(sql, config, db_name \\ "postgres") do
    {output, 0} = psql(config, db_name, sql)
    String.split(output, "\n", trim: true)
  end

  defp psql(config, db_name, sql) do
    System.cmd(
      "psql",
      [
        ["-h", config[:hostname], "-p", to_string(config[:port]), "-U", config[:username]],
        ["-d", db_name, "-Atc", sql]
      ]
      |> Enum.concat(),
      env: [{"PGPASSWORD", config[:password]}]
    )
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
    :ok = Sandbox.checkout(InternalRepo)
    :ok = Sandbox.checkout(MainRepo)

    # Set sandbox mode to manual for explicit control
    Sandbox.mode(InternalRepo, {:shared, self()})
    Sandbox.mode(MainRepo, {:shared, self()})

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
    SQL.query!(InternalRepo, "TRUNCATE TABLE users RESTART IDENTITY CASCADE")
    SQL.query!(MainRepo, "TRUNCATE TABLE users RESTART IDENTITY CASCADE")
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
             "-h",
             hostname,
             "-p",
             to_string(port),
             "-U",
             username,
             "-d",
             "postgres",
             "-c",
             "CREATE DATABASE #{db_name}"
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
             "-h",
             hostname,
             "-p",
             to_string(port),
             "-U",
             username,
             "-d",
             "postgres",
             "-c",
             "DROP DATABASE IF EXISTS #{db_name}"
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

    # users: test-only sync schema (Platform.Test.User).
    # file_chunks / missing_chunks: read by Sync.run_local_sync/1's chunk backfill;
    # mirror chat's columns, without FKs and triggers.
    sql = """
    CREATE TABLE IF NOT EXISTS users (
      pub_key bytea PRIMARY KEY,
      name text NOT NULL
    );
    CREATE TABLE IF NOT EXISTS file_chunks (
      file_id text NOT NULL,
      chunk_index integer NOT NULL,
      size integer NOT NULL,
      uploader_hash text NOT NULL,
      owner_timestamp bigint NOT NULL,
      sign_b64 bytea NOT NULL,
      data_hash text NOT NULL,
      PRIMARY KEY (file_id, chunk_index)
    );
    CREATE TABLE IF NOT EXISTS missing_chunks (
      file_id text NOT NULL,
      chunk_index integer NOT NULL,
      data_hash text,
      size integer,
      peer_url text,
      attempts integer DEFAULT 0 NOT NULL,
      updated_at bigint NOT NULL,
      source_drive_id text,
      PRIMARY KEY (file_id, chunk_index)
    );
    """

    case System.cmd(
           "psql",
           [
             "-h",
             hostname,
             "-p",
             to_string(port),
             "-U",
             username,
             "-d",
             db_name,
             "-c",
             sql
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
