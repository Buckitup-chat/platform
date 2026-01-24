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

        run_pg(
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

        run_pg(
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
    pg_dir = Keyword.fetch!(opts, :pg_dir)
    pg_port = Keyword.get(opts, :pg_port, 5432)
    pg_data_dir = Path.join(pg_dir, "data")

    ["Setting up replication configuration"] |> log(:info)

    # Update pg_hba.conf to allow replication connections
    hba_result = update_pg_hba_conf(pg_data_dir)

    case hba_result do
      :ok ->
        if Lifecycle.server_running?(opts) do
          # Reload PostgreSQL configuration if running
          case run_sql("SELECT pg_reload_conf();", pg_port: pg_port) do
            {:ok, _} ->
              ["Replication configuration setup successfully"] |> log(:info)
              :ok

            {:error, reason} ->
              ["Failed to reload PostgreSQL configuration: ", reason] |> log(:error)
              {:error, "Failed to reload configuration: #{reason}"}
          end
        else
          ["Replication configuration set (will apply on next start)"] |> log(:info)
          :ok
        end

      {:error, reason} ->
        log(["Failed to update pg_hba.conf: ", reason], :error)
        {:error, "Failed to update pg_hba.conf: #{reason}"}
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

    case File.read(hba_file) do
      {:ok, content} ->
        # Check if replication entry already exists
        if String.contains?(content, "# Replication connections") do
          ["pg_hba.conf already configured for replication"] |> log(:debug)
          :ok
        else
          # Add replication entries for postgres superuser
          replication_entries = """

          # Replication connections
          host    replication     #{@postgres_user}     127.0.0.1/32            trust
          host    replication     #{@postgres_user}     ::1/128                 trust
          local   replication     #{@postgres_user}                             trust
          """

          new_content = content <> replication_entries

          case File.write(hba_file, new_content) do
            :ok ->
              ["pg_hba.conf updated for replication connections"] |> log(:info)
              :ok

            {:error, reason} ->
              {:error, "Failed to write pg_hba.conf: #{inspect(reason)}"}
          end
        end

      {:error, reason} ->
        {:error, "Failed to read pg_hba.conf: #{inspect(reason)}"}
    end
  end

  @doc """
  Get replication user credentials.

  ## Returns
  A keyword list with `:username` for the postgres superuser (no password needed with trust auth).
  """
  def replication_credentials do
    [username: @postgres_user]
  end

  defp run_pg(tool, args, opts) do
    cmd_opts =
      Enum.reduce(opts, [stderr_to_stdout: true], fn
        {:as_postgres_user, true}, acc ->
          acc
          |> Keyword.put(:uid, Lifecycle.get_postgres_uid())
          |> Keyword.put(:gid, Lifecycle.get_postgres_gid())

        {:run_dir, run_dir}, acc ->
          # Set PGHOST to run_dir so pg_* tools use the correct socket directory
          env = Keyword.get(acc, :env, [])
          Keyword.put(acc, :env, [{"PGHOST", run_dir} | env])

        _, acc ->
          acc
      end)

    MuonTrap.cmd("/usr/bin/#{tool}", args, cmd_opts)
  end
end
