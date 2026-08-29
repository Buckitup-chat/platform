defmodule Platform.Tools.Postgres.Database do
  @moduledoc """
  PostgreSQL database operations and replication configuration.
  Handles database creation, SQL execution, and replication setup.
  """
  use Toolbox.OriginLog

  import Toolbox.Flow, only: [go_on: 2]

  alias Platform.Tools.Postgres.Lifecycle

  @postgres_user "postgres"
  @pg_host "localhost"

  @replication_marker "# Replication connections"

  @replication_entries """

  #{@replication_marker}
  host    replication     #{@postgres_user}     127.0.0.1/32            trust
  host    replication     #{@postgres_user}     ::1/128                 trust
  local   replication     #{@postgres_user}                             trust
  """

  @doc """
  Run a SQL command against the PostgreSQL database.

  ## Options
  - `:pg_port` - PostgreSQL port (default: 5432)
  - `:db_name` - Database name (default: "postgres")

  ## Returns
  - `{:ok, output}` if the SQL command was executed successfully
  - `{:error, output}` if the SQL command failed
  """
  def run_sql(sql, opts \\ []) do
    pg_port = Keyword.get(opts, :pg_port, 5432)
    db_name = Keyword.get(opts, :db_name, "postgres")

    Lifecycle.server_running?(opts)
    |> go_on(fn
      false ->
        ["Cannot run SQL: PostgreSQL server not running"] |> log(:error)
        {:error, "PostgreSQL server not running"}

      true ->
        ["Running SQL: #{sql} on database #{db_name}"] |> log(:debug)

        Lifecycle.run_pg(
          "psql",
          ["-U", @postgres_user, "-h", @pg_host, "-p", "#{pg_port}", "-d", db_name, "-c", sql],
          as_postgres_user: true
        )
    end)
    |> go_on(fn
      {output, 0} -> {:ok, output}
      {output, _} -> {:error, output}
    end)
  end

  @doc """
  Create a new PostgreSQL database.

  ## Options
  - `:pg_port` - PostgreSQL port (default: 5432)

  ## Returns
  - `{:ok, db_name}` if the database was created successfully
  - `{:error, output}` if the database failed to create
  - `{:error, "PostgreSQL server not running"}` if the PostgreSQL server is not running
  """
  def create_database(db_name, opts \\ []) do
    pg_port = Keyword.get(opts, :pg_port, 5432)

    Lifecycle.server_running?(opts)
    |> go_on(fn
      false ->
        ["Cannot create database: PostgreSQL server not running"] |> log(:error)
        {:error, "PostgreSQL server not running"}

      true ->
        {:ok, output} =
          run_sql("SELECT datname FROM pg_database WHERE datname = '#{db_name}';", opts)

        String.contains?(output, db_name)
    end)
    |> go_on(fn
      true ->
        ["Database '#{db_name}' already exists"] |> log(:info)
        {:ok, db_name}

      false ->
        ["Creating database: #{db_name}"] |> log(:info)

        Lifecycle.run_pg(
          "createdb",
          ["-U", @postgres_user, "-h", @pg_host, "-p", "#{pg_port}", db_name],
          as_postgres_user: true
        )
    end)
    |> go_on(fn
      {_, 0} ->
        ["Database '#{db_name}' created successfully"] |> log(:info)
        {:ok, db_name}

      {output, _} ->
        ["Failed to create database '#{db_name}': #{output}"] |> log(:error)
        {:error, output}
    end)
  end

  @doc """
  Ensure a database exists, creating it if necessary.

  ## Options
  - `:pg_port` - PostgreSQL port (default: 5432)

  ## Returns
  - `{:ok, db_name}` if the database exists
  - `{:error, output}` if the database does not exist
  """
  def ensure_db_exists(name, opts \\ []) do
    {:ok, output} = run_sql("SELECT datname FROM pg_database WHERE datname = '#{name}';", opts)

    if String.contains?(output, name) do
      ["Database '#{name}' already exists"] |> log(:info)
      {:ok, name}
    else
      ["Creating database '#{name}'"] |> log(:info)
      create_database(name, opts)
    end
  end

  @doc """
  Configure pg_hba.conf for replication connections using the postgres superuser.
  This should be called after PostgreSQL initialization.

  ## Options
  - `:pg_dir` - Base directory for PostgreSQL data (required)
  - `:pg_port` - PostgreSQL port (default: 5432)

  ## Returns
  - `:ok` if replication setup was successful
  - `{:error, reason}` if setup failed
  """
  def setup_replication(opts) do
    pg_data_dir = opts |> Keyword.fetch!(:pg_dir) |> Path.join("data")
    pg_port = Keyword.get(opts, :pg_port, 5432)

    ["Setting up replication configuration"] |> log(:info)

    with {:hba, :ok} <- {:hba, update_pg_hba_conf(pg_data_dir)},
         {:running, true} <- {:running, Lifecycle.server_running?(opts)},
         {:reload, {:ok, _}} <-
           {:reload, run_sql("SELECT pg_reload_conf();", pg_port: pg_port)} do
      ["Replication configuration setup successfully"] |> log(:info)
      :ok
    else
      {:hba, {:error, reason}} ->
        ["Failed to update pg_hba.conf: ", reason] |> log(:error)
        {:error, "Failed to update pg_hba.conf: #{reason}"}

      {:running, false} ->
        ["Replication configuration set (will apply on next start)"] |> log(:info)
        :ok

      {:reload, {:error, reason}} ->
        ["Failed to reload PostgreSQL configuration: ", reason] |> log(:error)
        {:error, "Failed to reload configuration: #{reason}"}
    end
  end

  @doc """
  Update pg_hba.conf to allow replication connections.

  ## Parameters
  - `pg_data_dir` - PostgreSQL data directory path

  ## Returns
  - `:ok` if pg_hba.conf was updated successfully
  - `{:error, reason}` if update failed
  """
  def update_pg_hba_conf(pg_data_dir) do
    hba_file = Path.join(pg_data_dir, "pg_hba.conf")

    with {:read, {:ok, content}} <- {:read, File.read(hba_file)},
         {:configured, false} <- {:configured, String.contains?(content, @replication_marker)},
         {:write, :ok} <- {:write, File.write(hba_file, content <> @replication_entries)} do
      ["pg_hba.conf updated for replication connections"] |> log(:info)
      :ok
    else
      {:read, {:error, reason}} ->
        {:error, "Failed to read pg_hba.conf: #{inspect(reason)}"}

      {:configured, true} ->
        ["pg_hba.conf already configured for replication"] |> log(:debug)
        :ok

      {:write, {:error, reason}} ->
        {:error, "Failed to write pg_hba.conf: #{inspect(reason)}"}
    end
  end

  @doc """
  Get replication user credentials.

  ## Returns
  A keyword list with `:username` for the postgres superuser (no password needed with trust auth).
  """
  def replication_credentials, do: [username: @postgres_user]
end
