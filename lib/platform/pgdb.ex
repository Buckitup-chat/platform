defmodule Platform.PgDb do
  @moduledoc """
  PostgreSQL database handling for Nerves environment.
  Initializes, starts, and manages the PostgreSQL server.

  ## Deprecation Notice

  This module is deprecated. Please use `Platform.Tools.Postgres` instead.
  All functions in this module now delegate to the new configurable implementation.
  """

  # Explicitly define MuonTrap dependency
  alias MuonTrap
  alias Platform.Tools.Postgres
  require Logger

  # Default locations
  @pg_data_dir "/root/pg/data"
  @pg_run_dir "/root/pg/run"
  @postgres_user "postgres"
  @pg_port Application.compile_env(:chat, :pg_port, 5432)
  @pg_host "localhost"

  @pg_minimal_settings [
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
    "unix_socket_directories=#{@pg_run_dir}"
  ]

  @doc """
  Returns the minimal PostgreSQL settings used for configuration.
  """
  @deprecated "Use Platform.Tools.Postgres instead"
  def minimal_settings do
    @pg_minimal_settings
  end

  @doc """
  Initialize the PostgreSQL database if not already initialized.
  Creates the data directory and performs `initdb`.
  """
  @deprecated "Use Platform.Tools.Postgres.initialize/1 instead"
  def initialize do
    Postgres.initialize(pg_dir: "/root/pg", pg_port: @pg_port)
  end

  @doc """
  Check if PostgreSQL is already initialized.
  """
  @deprecated "Use Platform.Tools.Postgres.initialized?/1 instead"
  def initialized? do
    Postgres.initialized?(pg_dir: "/root/pg")
  end

  @doc """
  Start the PostgreSQL server.
  """
  @deprecated "Use Platform.Tools.Postgres.start/1 instead"
  def start do
    Postgres.start(pg_dir: "/root/pg", pg_port: @pg_port)
  end

  @doc """
  Stop the PostgreSQL server.
  """
  @deprecated "Use Platform.Tools.Postgres.stop/1 instead"
  def stop do
    Postgres.stop(pg_dir: "/root/pg")
  end

  @doc """
  Run a SQL command against the PostgreSQL database.
  """
  @deprecated "Use Platform.Tools.Postgres.run_sql/2 instead"
  def run_sql(sql, db_name \\ "postgres") do
    Postgres.run_sql(sql, pg_port: @pg_port, db_name: db_name)
  end

  @doc """
  Create a new PostgreSQL database.
  """
  @deprecated "Use Platform.Tools.Postgres.create_database/2 instead"
  def create_database(db_name) do
    Postgres.create_database(db_name, pg_port: @pg_port)
  end

  @doc """
  Check if the PostgreSQL server is running.
  """
  @deprecated "Use Platform.Tools.Postgres.server_running?/1 instead"
  def server_running? do
    Postgres.server_running?(pg_port: @pg_port)
  end

  @deprecated "Use Platform.Tools.Postgres.ensure_db_exists/2 instead"
  def ensure_db_exists(name) do
    Postgres.ensure_db_exists(name, pg_port: @pg_port)
  end

  # All private helper functions have been moved to Platform.Tools.Postgres
  # This module now only serves as a deprecated compatibility layer
end
