defmodule Platform.PostgresTest do
  use ExUnit.Case, async: true

  import Rewire

  alias Platform.Tools.Postgres

  @moduletag :capture_log

  # Mock MuonTrap to capture commands and return controlled responses
  defmodule MuonTrapMock do
    def cmd(command, args, opts \\ []) do
      test_pid = Process.get(:test_pid)
      send(test_pid, {:muon_trap_cmd, command, args, opts})

      # Return different responses based on command
      case {command, args} do
        # initdb success
        {"/usr/bin/initdb", _} ->
          {"Database system initialized", 0}

        # pg_ctl start success
        {"/usr/bin/pg_ctl", args} ->
          if Enum.member?(args, "start") do
            {"server started", 0}
          else
            {"server stopped", 0}
          end

        # psql commands
        {"/usr/bin/psql", args} ->
          cond do
            # server_running? check
            Enum.member?(args, "SELECT 1") and not Enum.member?(args, "-d") -> {"", 0}
            # run_sql commands
            Enum.member?(args, "-c") -> {"query result", 0}
            true -> {"", 0}
          end

        # createdb success
        {"/usr/bin/createdb", _} ->
          {"", 0}

        # id commands for user/group
        {"id", ["-u", "postgres"]} ->
          {"999\n", 0}

        {"id", ["-g", "postgres"]} ->
          {"998\n", 0}

        # Default case
        _ ->
          {"command output", 0}
      end
    end
  end

  # Mock File module to capture file operations
  defmodule FileMock do
    def mkdir_p!(path) do
      test_pid = Process.get(:test_pid)
      send(test_pid, {:file_mkdir_p, path})
      :ok
    end

    def exists?(path) do
      test_pid = Process.get(:test_pid)
      send(test_pid, {:file_exists, path})

      # Return true for PG_VERSION to simulate initialized database
      case path do
        "/root/pg/data/PG_VERSION" -> true
        _ -> false
      end
    end

    def chmod!(path, mode) do
      test_pid = Process.get(:test_pid)
      send(test_pid, {:file_chmod, path, mode})
      :ok
    end

    def chown!(path, uid) do
      test_pid = Process.get(:test_pid)
      send(test_pid, {:file_chown, path, uid})
      :ok
    end

    def chgrp!(path, gid) do
      test_pid = Process.get(:test_pid)
      send(test_pid, {:file_chgrp, path, gid})
      :ok
    end

    def ls(path) do
      test_pid = Process.get(:test_pid)
      send(test_pid, {:file_ls, path})
      {:ok, []}
    end

    def dir?(path) do
      test_pid = Process.get(:test_pid)
      send(test_pid, {:file_dir, path})
      false
    end
  end

  # Test process to capture commands
  setup do
    test_pid = self()
    # Store test_pid in process dictionary for mocks to access
    Process.put(:test_pid, test_pid)
    :ok
  end

  # Additional mock modules for specific test scenarios
  defmodule FileMockNotInitialized do
    def mkdir_p!(path) do
      test_pid = Process.get(:test_pid)
      send(test_pid, {:file_mkdir_p, path})
      :ok
    end

    def exists?("/root/pg/data/PG_VERSION"), do: false
    def exists?(_), do: false

    def chmod!(path, mode) do
      test_pid = Process.get(:test_pid)
      send(test_pid, {:file_chmod, path, mode})
      :ok
    end

    def chown!(path, uid) do
      test_pid = Process.get(:test_pid)
      send(test_pid, {:file_chown, path, uid})
      :ok
    end

    def chgrp!(path, gid) do
      test_pid = Process.get(:test_pid)
      send(test_pid, {:file_chgrp, path, gid})
      :ok
    end

    def ls(path) do
      test_pid = Process.get(:test_pid)
      send(test_pid, {:file_ls, path})
      {:ok, []}
    end

    def dir?(path) do
      test_pid = Process.get(:test_pid)
      send(test_pid, {:file_dir, path})
      false
    end
  end

  defmodule MuonTrapMockNotRunning do
    def cmd("/usr/bin/psql", args, opts) do
      test_pid = Process.get(:test_pid)
      send(test_pid, {:muon_trap_cmd, "/usr/bin/psql", args, opts})

      if Enum.member?(args, "SELECT 1") and not Enum.member?(args, "-d") do
        {"connection failed", 1}
      else
        {"", 0}
      end
    end

    def cmd(command, args, opts) do
      test_pid = Process.get(:test_pid)
      send(test_pid, {:muon_trap_cmd, command, args, opts})

      case {command, args} do
        {"/usr/bin/pg_ctl", args} ->
          if Enum.member?(args, "start") do
            {"server started", 0}
          else
            {"", 0}
          end

        {"id", ["-u", "postgres"]} ->
          {"999\n", 0}

        {"id", ["-g", "postgres"]} ->
          {"999\n", 0}

        _ ->
          {"", 0}
      end
    end
  end

  defmodule MuonTrapMockSQLError do
    def cmd("/usr/bin/psql", args, opts) do
      test_pid = Process.get(:test_pid)
      send(test_pid, {:muon_trap_cmd, "/usr/bin/psql", args, opts})

      cond do
        Enum.member?(args, "SELECT 1") -> {"", 0}
        Enum.member?(args, "-c") -> {"ERROR: syntax error", 1}
        true -> {"", 0}
      end
    end

    def cmd(command, args, opts) do
      test_pid = Process.get(:test_pid)
      send(test_pid, {:muon_trap_cmd, command, args, opts})

      case {command, args} do
        {"id", ["-u", "postgres"]} -> {"999\n", 0}
        {"id", ["-g", "postgres"]} -> {"999\n", 0}
        _ -> {"", 0}
      end
    end
  end

  defmodule MuonTrapMockNewDB do
    def cmd("/usr/bin/psql", args, opts) do
      test_pid = Process.get(:test_pid)
      send(test_pid, {:muon_trap_cmd, "/usr/bin/psql", args, opts})

      cond do
        Enum.member?(args, "SELECT 1") -> {"", 0}
        # Empty result means database doesn't exist
        Enum.member?(args, "-c") -> {"", 0}
        true -> {"", 0}
      end
    end

    def cmd("/usr/bin/createdb", args, opts) do
      test_pid = Process.get(:test_pid)
      send(test_pid, {:muon_trap_cmd, "/usr/bin/createdb", args, opts})
      {"", 0}
    end

    def cmd(command, args, opts) do
      test_pid = Process.get(:test_pid)
      send(test_pid, {:muon_trap_cmd, command, args, opts})

      case {command, args} do
        {"id", ["-u", "postgres"]} -> {"999\n", 0}
        {"id", ["-g", "postgres"]} -> {"999\n", 0}
        _ -> {"", 0}
      end
    end
  end

  defmodule MuonTrapMockExistingDB do
    def cmd("/usr/bin/psql", args, opts) do
      test_pid = Process.get(:test_pid)
      send(test_pid, {:muon_trap_cmd, "/usr/bin/psql", args, opts})

      cond do
        Enum.member?(args, "SELECT 1") -> {"", 0}
        # Database name in result means it exists
        Enum.member?(args, "-c") -> {"testdb", 0}
        true -> {"", 0}
      end
    end

    def cmd(command, args, opts) do
      test_pid = Process.get(:test_pid)
      send(test_pid, {:muon_trap_cmd, command, args, opts})

      case {command, args} do
        {"id", ["-u", "postgres"]} -> {"999\n", 0}
        {"id", ["-g", "postgres"]} -> {"999\n", 0}
        _ -> {"", 0}
      end
    end
  end

  defmodule MuonTrapMockEnsureNew do
    def cmd("/usr/bin/psql", args, opts) do
      test_pid = Process.get(:test_pid)
      send(test_pid, {:muon_trap_cmd, "/usr/bin/psql", args, opts})

      cond do
        Enum.member?(args, "SELECT 1") -> {"", 0}
        # Empty result means database doesn't exist
        Enum.member?(args, "-c") -> {"", 0}
        true -> {"", 0}
      end
    end

    def cmd("/usr/bin/createdb", args, opts) do
      test_pid = Process.get(:test_pid)
      send(test_pid, {:muon_trap_cmd, "/usr/bin/createdb", args, opts})
      {"", 0}
    end

    def cmd(command, args, opts) do
      test_pid = Process.get(:test_pid)
      send(test_pid, {:muon_trap_cmd, command, args, opts})

      case {command, args} do
        {"id", ["-u", "postgres"]} -> {"999\n", 0}
        {"id", ["-g", "postgres"]} -> {"999\n", 0}
        _ -> {"", 0}
      end
    end
  end

  defmodule MuonTrapMockEnsureExisting do
    def cmd("/usr/bin/psql", args, opts) do
      test_pid = Process.get(:test_pid)
      send(test_pid, {:muon_trap_cmd, "/usr/bin/psql", args, opts})

      cond do
        Enum.member?(args, "SELECT 1") -> {"", 0}
        # Database name in result means it exists
        Enum.member?(args, "-c") -> {"existingdb", 0}
        true -> {"", 0}
      end
    end

    def cmd(command, args, opts) do
      test_pid = Process.get(:test_pid)
      send(test_pid, {:muon_trap_cmd, command, args, opts})

      case {command, args} do
        {"id", ["-u", "postgres"]} -> {"999\n", 0}
        {"id", ["-g", "postgres"]} -> {"999\n", 0}
        _ -> {"", 0}
      end
    end
  end

  defmodule MuonTrapMockStartServer do
    def cmd("/usr/bin/psql", args, opts) do
      test_pid = Process.get(:test_pid)
      send(test_pid, {:muon_trap_cmd, "/usr/bin/psql", args, opts})

      # Check if we've already started the server by looking at process dictionary
      started = Process.get(:server_started, false)

      if Enum.member?(args, "SELECT 1") and not Enum.member?(args, "-d") do
        if started do
          # Server is running after start
          {"", 0}
        else
          # Server not running initially
          {"connection failed", 1}
        end
      else
        {"", 0}
      end
    end

    def cmd(command, args, opts) do
      test_pid = Process.get(:test_pid)
      send(test_pid, {:muon_trap_cmd, command, args, opts})

      case {command, args} do
        {"/usr/bin/pg_ctl", args} ->
          if Enum.member?(args, "start") do
            Process.put(:server_started, true)
            {"server started", 0}
          else
            {"", 0}
          end

        {"id", ["-u", "postgres"]} ->
          {"999\n", 0}

        {"id", ["-g", "postgres"]} ->
          {"999\n", 0}

        _ ->
          {"", 0}
      end
    end
  end

  # Apply rewire to mock the modules - rewire Platform.Tools.Postgres directly
  rewire(Postgres, MuonTrap: MuonTrapMock, File: FileMock)

  # Default options for tests
  @default_opts [pg_dir: "/root/pg", pg_port: 5432]

  describe "initialized?/1" do
    test "checks if PostgreSQL is initialized by looking for PG_VERSION file" do
      assert Postgres.initialized?(@default_opts) == true
      assert_received {:file_exists, "/root/pg/data/PG_VERSION"}
    end
  end

  describe "initialize/1" do
    test "initializes PostgreSQL when not already initialized" do
      rewire(Postgres,
        File: FileMockNotInitialized,
        MuonTrap: MuonTrapMock
      ) do
        assert Postgres.initialize(@default_opts) == :ok

          # Verify directories were created
          assert_received {:file_mkdir_p, "/root/pg/data"}
          assert_received {:file_mkdir_p, "/tmp/pg_run"}

          # Capture exact initdb command
          assert_received {:muon_trap_cmd, "/usr/bin/initdb", args, opts}

          assert args == [
                   "--auth-host=trust",
                   "--auth-local=trust",
                   "-D",
                   "/root/pg/data",
                   "-c",
                   "shared_buffers=400kB",
                   "-c",
                   "max_connections=15",
                   "-c",
                   "dynamic_shared_memory_type=mmap",
                   "-c",
                   "max_prepared_transactions=0",
                   "-c",
                   "max_locks_per_transaction=32",
                   "-c",
                   "max_files_per_process=64",
                   "-c",
                   "work_mem=1MB",
                   "-c",
                   "wal_level=logical",
                   "-c",
                   "listen_addresses=localhost",
                   "-c",
                   "unix_socket_directories=/tmp/pg_run"
                 ]

        assert opts == [uid: 999, stderr_to_stdout: true]

        # Verify id commands were called to get postgres user/group IDs
        assert_received {:muon_trap_cmd, "id", id_u_args, id_u_opts}
        assert id_u_args == ["-u", "postgres"]
        assert id_u_opts == [stderr_to_stdout: true]

        assert_received {:muon_trap_cmd, "id", id_g_args, id_g_opts}
        assert id_g_args == ["-g", "postgres"]
        assert id_g_opts == [stderr_to_stdout: true]
      end
    end

    test "skips initialization when already initialized" do
      assert Postgres.initialize(@default_opts) == :ok

      # Should still create directories and set permissions
      assert_received {:file_mkdir_p, "/root/pg/data"}
      assert_received {:file_mkdir_p, "/tmp/pg_run"}

      # Should not call initdb since already initialized
      refute_received {:muon_trap_cmd, "/usr/bin/initdb", _, _}
    end
  end

  describe "start/1" do
    test "starts PostgreSQL server when not running" do
      rewire(Postgres,
        MuonTrap: MuonTrapMockStartServer,
        File: FileMock
      ) do
        assert Postgres.start(@default_opts) == :ok

          # First call is server_running? check (should fail initially)
          assert_received {:muon_trap_cmd, "/usr/bin/psql", server_check_args, server_check_opts}

          assert server_check_args == [
                   "-U",
                   "postgres",
                   "-h",
                   "localhost",
                   "-p",
                   "5432",
                   "-c",
                   "SELECT 1"
                 ]

          assert server_check_opts == [stderr_to_stdout: true]

          # Second call is pg_ctl start command - capture exact command
          assert_received {:muon_trap_cmd, "/usr/bin/pg_ctl", args, opts}

          assert args == [
                   "-D",
                   "/root/pg/data",
                   "-l",
                   "/dev/null",
                   "-o",
                   "-c shared_buffers=400kB -c max_connections=15 -c dynamic_shared_memory_type=mmap -c max_prepared_transactions=0 -c max_locks_per_transaction=32 -c max_files_per_process=64 -c work_mem=1MB -c wal_level=logical -c listen_addresses=localhost -c unix_socket_directories=/tmp/pg_run -c port=5432 -c listen_addresses='localhost' -c log_destination=stderr",
                   "start"
                 ]

          assert opts == [uid: 999, stderr_to_stdout: true]

          # Third call is server_running? check again (should succeed after start)
          assert_received {:muon_trap_cmd, "/usr/bin/psql", final_check_args, final_check_opts}

          assert final_check_args == [
                   "-U",
                   "postgres",
                   "-h",
                   "localhost",
                   "-p",
                   "5432",
                   "-c",
                   "SELECT 1"
                 ]

        assert final_check_opts == [stderr_to_stdout: true]
      end
    end

    test "skips start when PostgreSQL is already running" do
      assert Postgres.start(@default_opts) == :ok

      # Should check if running - capture exact command
      assert_received {:muon_trap_cmd, "/usr/bin/psql", server_check_args, server_check_opts}

      assert server_check_args == [
               "-U",
               "postgres",
               "-h",
               "localhost",
               "-p",
               "5432",
               "-c",
               "SELECT 1"
             ]

      assert server_check_opts == [stderr_to_stdout: true]

      # Should not call pg_ctl start
      refute_received {:muon_trap_cmd, "/usr/bin/pg_ctl", _, _}
    end
  end

  describe "stop/1" do
    test "stops PostgreSQL server when running" do
      assert Postgres.stop(@default_opts) == :ok

      # Capture exact pg_ctl stop command
      assert_received {:muon_trap_cmd, "/usr/bin/pg_ctl", args, opts}
      assert args == ["-D", "/root/pg/data", "stop", "-m", "fast"]
      assert opts == [uid: 999, stderr_to_stdout: true]
    end

    test "skips stop when PostgreSQL is not running" do
      rewire(Postgres,
        MuonTrap: MuonTrapMockNotRunning,
        File: FileMock
      ) do
        assert Postgres.stop(@default_opts) == :ok

          # Should check if running - capture exact command
          assert_received {:muon_trap_cmd, "/usr/bin/psql", args, opts}
          assert args == ["-U", "postgres", "-h", "localhost", "-p", "5432", "-c", "SELECT 1"]
          assert opts == [stderr_to_stdout: true]

        # Should not call pg_ctl stop
        refute_received {:muon_trap_cmd, "/usr/bin/pg_ctl", _, _}
      end
    end
  end

  describe "server_running?/1" do
    test "returns true when PostgreSQL server is running" do
      assert Postgres.server_running?(@default_opts) == true

      # Capture exact command to preserve behavior
      assert_received {:muon_trap_cmd, "/usr/bin/psql", args, opts}
      assert args == ["-U", "postgres", "-h", "localhost", "-p", "5432", "-c", "SELECT 1"]
      assert opts == [stderr_to_stdout: true]
    end

    test "returns false when PostgreSQL server is not running" do
      rewire(Postgres,
        MuonTrap: MuonTrapMockNotRunning,
        File: FileMock
      ) do
        assert Postgres.server_running?(@default_opts) == false
        assert_received {:muon_trap_cmd, "/usr/bin/psql", args, opts}
        assert args == ["-U", "postgres", "-h", "localhost", "-p", "5432", "-c", "SELECT 1"]
        assert opts == [stderr_to_stdout: true]
      end
    end
  end

  describe "run_sql/2" do
    test "runs SQL command with default database" do
      assert {:ok, "query result"} = Postgres.run_sql("SELECT * FROM users", @default_opts)

      # First call is server_running? check - capture exact command
      assert_received {:muon_trap_cmd, "/usr/bin/psql", server_check_args, server_check_opts}

      assert server_check_args == [
               "-U",
               "postgres",
               "-h",
               "localhost",
               "-p",
               "5432",
               "-c",
               "SELECT 1"
             ]

      assert server_check_opts == [stderr_to_stdout: true]

      # Second call is the actual SQL execution - capture exact command
      assert_received {:muon_trap_cmd, "/usr/bin/psql", args, opts}

      assert args == [
               "-U",
               "postgres",
               "-h",
               "localhost",
               "-p",
               "5432",
               "-d",
               "postgres",
               "-c",
               "SELECT * FROM users"
             ]

      assert opts == [uid: 999, stderr_to_stdout: true]
    end

    test "runs SQL command with specified database" do
      assert {:ok, "query result"} = Postgres.run_sql("CREATE TABLE test (id INT)", Keyword.put(@default_opts, :db_name, "testdb"))

      # First call is server_running? check - capture exact command
      assert_received {:muon_trap_cmd, "/usr/bin/psql", server_check_args, server_check_opts}

      assert server_check_args == [
               "-U",
               "postgres",
               "-h",
               "localhost",
               "-p",
               "5432",
               "-c",
               "SELECT 1"
             ]

      assert server_check_opts == [stderr_to_stdout: true]

      # Second call is the actual SQL execution - capture exact command
      assert_received {:muon_trap_cmd, "/usr/bin/psql", args, opts}

      assert args == [
               "-U",
               "postgres",
               "-h",
               "localhost",
               "-p",
               "5432",
               "-d",
               "testdb",
               "-c",
               "CREATE TABLE test (id INT)"
             ]

      assert opts == [uid: 999, stderr_to_stdout: true]
    end

    test "returns error when server is not running" do
      rewire(Postgres,
        MuonTrap: MuonTrapMockNotRunning,
        File: FileMock
      ) do
        assert {:error, "PostgreSQL server not running"} = Postgres.run_sql("SELECT 1", @default_opts)
      end
    end

    test "returns error when SQL command fails" do
      rewire(Postgres,
        MuonTrap: MuonTrapMockSQLError,
        File: FileMock
      ) do
        assert {:error, "ERROR: syntax error"} = Postgres.run_sql("INVALID SQL", @default_opts)
      end
    end
  end

  describe "create_database/2" do
    test "creates new database when it doesn't exist" do
      rewire(Postgres, MuonTrap: MuonTrapMockNewDB, File: FileMock) do
        assert {:ok, "testdb"} = Postgres.create_database("testdb", @default_opts)

          # First call is server_running? check from create_database
          assert_received {:muon_trap_cmd, "/usr/bin/psql", server_check_args1,
                           server_check_opts1}

          assert server_check_args1 == [
                   "-U",
                   "postgres",
                   "-h",
                   "localhost",
                   "-p",
                   "5432",
                   "-c",
                   "SELECT 1"
                 ]

          assert server_check_opts1 == [stderr_to_stdout: true]

          # Second call is server_running? check from run_sql (inside create_database)
          assert_received {:muon_trap_cmd, "/usr/bin/psql", server_check_args2,
                           server_check_opts2}

          assert server_check_args2 == [
                   "-U",
                   "postgres",
                   "-h",
                   "localhost",
                   "-p",
                   "5432",
                   "-c",
                   "SELECT 1"
                 ]

          assert server_check_opts2 == [stderr_to_stdout: true]

          # Third call checks if database exists
          assert_received {:muon_trap_cmd, "/usr/bin/psql", db_check_args, db_check_opts}

          assert db_check_args == [
                   "-U",
                   "postgres",
                   "-h",
                   "localhost",
                   "-p",
                   "5432",
                   "-d",
                   "postgres",
                   "-c",
                   "SELECT datname FROM pg_database WHERE datname = 'testdb';"
                 ]

          assert db_check_opts == [uid: 999, stderr_to_stdout: true]

        # Fourth call creates the database
        assert_received {:muon_trap_cmd, "/usr/bin/createdb", args, opts}
        assert args == ["-U", "postgres", "-h", "localhost", "-p", "5432", "testdb"]
        assert opts == [uid: 999, stderr_to_stdout: true]
      end
    end

    test "skips creation when database already exists" do
      rewire(Postgres,
        MuonTrap: MuonTrapMockExistingDB,
        File: FileMock
      ) do
        assert {:ok, "testdb"} = Postgres.create_database("testdb", @default_opts)

        # Should not call createdb
        refute_received {:muon_trap_cmd, "/usr/bin/createdb", _, _}
      end
    end

    test "returns error when server is not running" do
      rewire(Postgres,
        MuonTrap: MuonTrapMockNotRunning,
        File: FileMock
      ) do
        assert {:error, "PostgreSQL server not running"} = Postgres.create_database("testdb", @default_opts)
      end
    end
  end

  describe "ensure_db_exists/2" do
    test "creates database when it doesn't exist" do
      rewire(Postgres,
        MuonTrap: MuonTrapMockEnsureNew,
        File: FileMock
      ) do
        assert {:ok, "newdb"} = Postgres.ensure_db_exists("newdb", @default_opts)

        # Should call createdb - capture exact command
        assert_received {:muon_trap_cmd, "/usr/bin/createdb", args, opts}
        assert args == ["-U", "postgres", "-h", "localhost", "-p", "5432", "newdb"]
        assert opts == [uid: 999, stderr_to_stdout: true]
      end
    end

    test "returns existing database when it already exists" do
      rewire(Postgres,
        MuonTrap: MuonTrapMockEnsureExisting,
        File: FileMock
      ) do
        assert {:ok, "existingdb"} = Postgres.ensure_db_exists("existingdb", @default_opts)

        # Should not call createdb
        refute_received {:muon_trap_cmd, "/usr/bin/createdb", _, _}
      end
    end
  end

  describe "private functions through public interface" do
    test "get_postgres_uid and get_postgres_gid are called during initialization" do
      rewire(Postgres,
        File: FileMockNotInitialized,
        MuonTrap: MuonTrapMock
      ) do
        Postgres.initialize(@default_opts)

        # Verify id commands were called to get postgres user/group IDs
        assert_received {:muon_trap_cmd, "id", args1, opts1}
        assert args1 == ["-u", "postgres"]
        assert opts1 == [stderr_to_stdout: true]

        assert_received {:muon_trap_cmd, "id", args2, opts2}
        assert args2 == ["-g", "postgres"]
        assert opts2 == [stderr_to_stdout: true]
      end
    end

    test "ensure_dirs_permissions is called during initialization" do
      rewire(Postgres,
        File: FileMockNotInitialized,
        MuonTrap: MuonTrapMock
      ) do
        Postgres.initialize(@default_opts)

        # Verify directory permissions were set
        assert_received {:file_chown, "/root/pg/data", 999}
        assert_received {:file_chgrp, "/root/pg/data", 998}
        assert_received {:file_chmod, "/root/pg/data", 0o750}

        assert_received {:file_chown, "/tmp/pg_run", 999}
        assert_received {:file_chgrp, "/tmp/pg_run", 998}
        assert_received {:file_chmod, "/tmp/pg_run", 0o750}
      end
    end
  end
end
