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


  # def initialize do
  #   File.mkdir_p!(@pg_data_dir)
  #   File.mkdir_p!(@pg_run_dir)

  #   [@pg_data_dir, @pg_run_dir]
  #   |> ensure_dirs_permissions(get_postgres_uid(), get_postgres_gid())

  #   File.chmod!("/root/pg", 0o755)

  #   initialized?()
  #   |> go_on(fn
  #     true ->
  #       Logger.info("PostgreSQL database already initialized")
  #       :ok

  #     false ->
  #       args =
  #         ["--auth-host=trust", "--auth-local=trust", "-D", @pg_data_dir] ++ @pg_minimal_settings

  #       Logger.info("Initializing PostgreSQL database")
  #       run_pg("initdb", args, as_postgres_user: true)
  #   end)
  #   |> go_on(fn
  #     {_, 0} ->
  #       Logger.info("PostgreSQL database initialized successfully")
  #       :ok

  #     {output, _} ->
  #       Logger.error("PostgreSQL database initialization failed: #{output}")
  #       {:error, output}
  #   end)
  # end

  # @doc """
  # Check if PostgreSQL is already initialized.
  # """
  # def initialized? do
  #   File.exists?("#{@pg_data_dir}/PG_VERSION")
  # end

  # @doc """
  # Start the PostgreSQL server.
  # """
  # @deprecated "Use Platform.Tools.Postgres.start/1 instead"
  # def start do
  #   server_running?()
  #   |> go_on(fn
  #     true ->
  #       Logger.info("PostgreSQL already running")
  #       :ok

  #     false ->
  #       args = [
  #         "-D",
  #         @pg_data_dir,
  #         "-l",
  #         "/dev/null",
  #         "-o",
  #         "#{Enum.join(@pg_minimal_settings, " ")} -c port=#{@pg_port} -c listen_addresses='localhost' -c log_destination=stderr",
  #         "start"
  #       ]

  #       Logger.info("Starting PostgreSQL server")
  #       run_pg("pg_ctl", args, as_postgres_user: true)
  #   end)
  #   |> go_on(fn
  #     {output, status} when status != 0 ->
  #       Logger.error("PostgreSQL server failed to start: #{output}")
  #       {:error, output}

  #     {output, 0} ->
  #       Process.sleep(1000)
  #       {output, server_running?()}
  #   end)
  #   |> go_on(fn
  #     {_, true} ->
  #       Logger.info("PostgreSQL server started successfully")
  #       :ok

  #     {output, false} ->
  #       Logger.error("PostgreSQL server failed to start: #{output}")
  #       {:error, output}
  #   end)
  # end

  # @doc """
  # Stop the PostgreSQL server.
  # """
  # @deprecated "Use Platform.Tools.Postgres.stop/1 instead"
  # def stop do
  #   server_running?()
  #   |> go_on(fn
  #     false ->
  #       Logger.info("PostgreSQL server not running")
  #       :ok

  #     true ->
  #       Logger.info("Stopping PostgreSQL server")
  #       args = ["-D", @pg_data_dir, "stop", "-m", "fast"]

  #       run_pg("pg_ctl", args, as_postgres_user: true)
  #   end)
  #   |> go_on(fn
  #     {_, 0} ->
  #       Logger.info("PostgreSQL server stopped successfully")
  #       :ok

  #     {output, _} ->
  #       Logger.error("PostgreSQL server failed to stop: #{output}")
  #       {:error, output}
  #   end)
  # end

  # @doc """
  # Run a SQL command against the PostgreSQL database.
  # """
  # @deprecated "Use Platform.Tools.Postgres.run_sql/2 instead"
  # def run_sql(sql, db_name \\ "postgres") do
  #   server_running?()
  #   |> go_on(fn
  #     false ->
  #       Logger.error("Cannot run SQL: PostgreSQL server not running")
  #       {:error, "PostgreSQL server not running"}

  #     true ->
  #       Logger.debug("Running SQL: #{sql} on database #{db_name}")

  #       run_pg(
  #         "psql",
  #         ["-U", @postgres_user, "-h", @pg_host, "-p", "#{@pg_port}", "-d", db_name, "-c", sql],
  #         as_postgres_user: true
  #       )
  #   end)
  #   |> go_on(fn
  #     {output, 0} -> {:ok, output}
  #     {output, _} -> {:error, output}
  #   end)
  # end

  # @doc """
  # Create a new PostgreSQL database.
  # """
  # @deprecated "Use Platform.Tools.Postgres.create_database/2 instead"
  # def create_database(db_name) do
  #   server_running?()
  #   |> go_on(fn
  #     false ->
  #       Logger.error("Cannot create database: PostgreSQL server not running")
  #       {:error, "PostgreSQL server not running"}

  #     true ->
  #       {:ok, output} = run_sql("SELECT datname FROM pg_database WHERE datname = '#{db_name}';")

  #       String.contains?(output, db_name)
  #   end)
  #   |> go_on(fn
  #     true ->
  #       Logger.info("Database '#{db_name}' already exists")
  #       {:ok, db_name}

  #     false ->
  #       Logger.info("Creating database: #{db_name}")

  #       run_pg(
  #         "createdb",
  #         ["-U", @postgres_user, "-h", @pg_host, "-p", "#{@pg_port}", db_name],
  #         as_postgres_user: true
  #       )
  #   end)
  #   |> go_on(fn
  #     {_, 0} ->
  #       Logger.info("Database '#{db_name}' created successfully")
  #       {:ok, db_name}

  #     {output, _} ->
  #       Logger.error("Failed to create database '#{db_name}': #{output}")
  #       {:error, output}
  #   end)
  # end

  # @doc """
  # Check if the PostgreSQL server is running.
  # """
  # @deprecated "Use Platform.Tools.Postgres.server_running?/1 instead"
  # def server_running? do
  #   sql = "SELECT 1"

  #   {_, status} =
  #     run_pg("psql", ["-U", @postgres_user, "-h", @pg_host, "-p", "#{@pg_port}", "-c", sql])

  #   status == 0
  # end

  # @deprecated "Use Platform.Tools.Postgres.ensure_db_exists/2 instead"
  # def ensure_db_exists(name) do
  #   {:ok, output} = run_sql("SELECT datname FROM pg_database WHERE datname = '#{name}';")

  #   if String.contains?(output, name) do
  #     Logger.info("Database '#{name}' already exists")
  #     {:ok, name}
  #   else
  #     Logger.info("Creating database '#{name}'")
  #     create_database(name)
  #   end
  # end

  # defp ensure_dirs_permissions([], _uid, _gid), do: :ok

  # defp ensure_dirs_permissions([dir | rest], uid, gid) do
  #   File.chown!(dir, uid)
  #   File.chgrp!(dir, gid)
  #   File.chmod!(dir, 0o750)

  #   {:ok, filelist} = File.ls(dir)

  #   Enum.reduce(filelist, rest, fn file_or_dir, acc ->
  #     path = Path.join(dir, file_or_dir)

  #     if File.dir?(path) do
  #       [path | acc]
  #     else
  #       File.chown!(path, uid)
  #       File.chgrp!(path, gid)
  #       File.chmod!(path, 0o750)
  #       acc
  #     end
  #   end)
  #   |> ensure_dirs_permissions(uid, gid)
  # end

  # defp run_pg(tool, args, opts \\ []) do
  #   cmd_opts =
  #     Enum.reduce(opts, [stderr_to_stdout: true], fn
  #       {:as_postgres_user, true}, acc -> Keyword.put(acc, :uid, get_postgres_uid())
  #       _, acc -> acc
  #     end)

  #   MuonTrap.cmd("/usr/bin/#{tool}", args, cmd_opts)
  # end

  # # Helper to get postgres user ID
  # defp get_postgres_uid do
  #   {uid_str, 0} = MuonTrap.cmd("id", ["-u", @postgres_user], stderr_to_stdout: true)
  #   String.trim(uid_str) |> String.to_integer()
  # end

  # defp get_postgres_gid do
  #   {gid_str, 0} = MuonTrap.cmd("id", ["-g", @postgres_user], stderr_to_stdout: true)
  #   String.trim(gid_str) |> String.to_integer()
  # end

  # defp go_on(data, step_fn) do
  #   case data do
  #     {:error, _} -> data
  #     {:ok, _} -> data
  #     :ok -> data
  #     _ -> step_fn.(data)
  #   end
  # end

end
