defmodule Platform.Tools.Postgres do
  @moduledoc """
  Configurable PostgreSQL tools that wrap Platform.PgDb functionality.
  All configuration is passed as options rather than using hardcoded values.
  """

  alias Platform.Tools.Postgres.{Lifecycle, Database, Permissions, SharedMemory}

  # Lifecycle operations
  defdelegate initialize(opts, retries \\ 5), to: Lifecycle
  defdelegate initialized?(opts), to: Lifecycle
  defdelegate valid_init?(opts), to: Lifecycle
  defdelegate clean_data_dir(opts), to: Lifecycle
  defdelegate start(opts), to: Lifecycle
  defdelegate stop(opts), to: Lifecycle
  defdelegate server_running?(opts \\ []), to: Lifecycle
  defdelegate ensure_run_dir(pg_dir, opts \\ []), to: Lifecycle
  defdelegate cleanup_run_dir_files(run_dir), to: Lifecycle
  defdelegate remove_stale_postmaster_pid(pg_dir), to: Lifecycle
  defdelegate cleanup_old_server(pg_dir, opts \\ []), to: Lifecycle

  # Database operations
  defdelegate run_sql(sql, opts \\ []), to: Database
  defdelegate create_database(db_name, opts \\ []), to: Database
  defdelegate ensure_db_exists(name, opts \\ []), to: Database
  defdelegate setup_replication(opts), to: Database
  defdelegate update_pg_hba_conf(pg_data_dir), to: Database
  defdelegate replication_credentials(), to: Database

  # Permissions
  defdelegate make_accessible(path), to: Permissions
  defdelegate get_postgres_uid(), to: Lifecycle
  defdelegate get_postgres_gid(), to: Lifecycle

  # Shared memory
  defdelegate cleanup_stale_shared_memory(pg_data_dir), to: SharedMemory, as: :cleanup_stale
  defdelegate cleanup_posix_shared_memory(), to: SharedMemory, as: :cleanup_posix

  @doc """
  Build a PostgreSQL connection string from an Ecto repo configuration.

  ## Parameters
  - `repo` - An Ecto repository module
  - `opts` - Optional keyword list with overrides:
    - `:port` - Override the port from repo config (useful for dynamically started repos)

  ## Returns
  A connection string in the format: "host=... port=... dbname=... user=... password=..."
  """
  def build_connection_string(repo, opts \\ []) do
    config = repo.config()
    host = Keyword.get(config, :hostname, "localhost")
    # Allow port override for dynamically started repos
    port = Keyword.get(opts, :port) || Keyword.get(config, :port, 5432)
    database = Keyword.get(config, :database, "chat")
    username = Keyword.get(config, :username, "postgres")
    password = Keyword.get(config, :password, "")

    "host=#{host} port=#{port} dbname=#{database} user=#{username} password=#{password}"
  end

  @doc """
  Create a daemon specification for running PostgreSQL server under supervision.

  ## Options
  - `:pg_dir` - Base directory for PostgreSQL data and run directories (required)
  - `:pg_port` - PostgreSQL port (default: 5432)
  - `:name` - Name for the daemon process (default: :postgres_daemon)
  """
  def daemon_spec(opts) do
    pg_dir = Keyword.fetch!(opts, :pg_dir)
    pg_port = Keyword.get(opts, :pg_port, 5432)
    daemon_name = Keyword.get(opts, :name, :postgres_daemon)

    run_dir = Lifecycle.extract_pg_run_dir(pg_dir, opts)
    pg_data_dir = Path.join(pg_dir, "data")

    {MuonTrap.Daemon,
     [
       "/usr/bin/postgres",
       ["-D", pg_data_dir] ++
         Lifecycle.minimal_settings() ++
         Lifecycle.recovery_optimized_settings() ++
         ~w[
           -c unix_socket_directories=#{run_dir}
           -c port=#{pg_port}
           -c log_destination=stderr
         ],
       [
         stderr_to_stdout: true,
         log_output: :debug,
         uid: Lifecycle.get_postgres_uid(),
         gid: Lifecycle.get_postgres_gid(),
         name: daemon_name
       ]
     ]}
  end
end
