defmodule Platform.Tools.Postgres.Lifecycle.Init do
  @moduledoc """
  PostgreSQL database initialization.
  Handles initdb, validation, and data directory management.
  """
  use Toolbox.OriginLog

  import Toolbox.Flow, only: [go_on: 2]

  alias Platform.Tools.Postgres.{Lifecycle, Permissions, SharedMemory}

  @doc """
  Initialize the PostgreSQL database with configurable options.

  ## Options
  - `:pg_dir` - Base directory for PostgreSQL data and run directories (required)

  ## Returns
  - `:ok` if the PostgreSQL database was initialized successfully
  - `{:error, output}` if the PostgreSQL database failed to initialize
  """
  def initialize(opts, retries \\ 5) do
    SharedMemory.cleanup_posix()

    pg_dir = Keyword.fetch!(opts, :pg_dir)
    pg_data_dir = Path.join(pg_dir, "data")
    run_dir = Lifecycle.ensure_run_dir(pg_dir, opts)

    prepare_data_dir(pg_data_dir, pg_dir, run_dir)

    check_init_state = fn
      {true, true} ->
        ["database already initialized at ", pg_data_dir] |> log(:info)
        :ok

      {true, false} ->
        [
          "CRITICAL: PostgreSQL data directory exists but is INVALID at ",
          pg_data_dir,
          " - may contain user data, skipping re-initialization"
        ]
        |> log(:critical)

        {:error, :incorrectly_initialized}

      {false, _} ->
        run_fresh_initdb(pg_data_dir, run_dir)
    end

    evaluate_initdb_output = fn
      {output, code} when code != 0 ->
        ["PostgreSQL database initialization failed: ", output] |> log(:error)
        {:error, output}

      {_, 0} ->
        valid_init?(opts)
    end

    setup_replication_if_valid = fn
      true ->
        Platform.Tools.Postgres.Database.setup_replication(opts)
        :ok

      false ->
        retries - 1
    end

    retry_or_fail = fn
      retries_left when retries_left < 1 ->
        ["PostgreSQL initialization failed after retries"] |> log(:error)
        {:error, :failed_after_retries}

      retries_left ->
        ["PostgreSQL initialization produced invalid data directory, cleaning and retrying"]
        |> log(:warning)

        clean_data_dir(opts)
        initialize(opts, retries_left)
    end

    {initialized?(opts), valid_init?(opts)}
    |> go_on(check_init_state)
    |> go_on(evaluate_initdb_output)
    |> go_on(setup_replication_if_valid)
    |> go_on(retry_or_fail)
  end

  @doc """
  Check if PostgreSQL is already initialized.

  ## Options
  - `:pg_dir` - Base directory for PostgreSQL data (required)
  """
  def initialized?(opts) do
    pg_dir = Keyword.fetch!(opts, :pg_dir)
    pg_data_dir = Path.join(pg_dir, "data")
    File.exists?(Path.join(pg_data_dir, "PG_VERSION"))
  end

  @doc """
  Validate that a PostgreSQL data directory is properly initialized.
  Checks for essential files and directories that must exist after a successful initdb.

  ## Options
  - `:pg_dir` - Base directory for PostgreSQL data (required)

  ## Returns
  - `true` if the data directory appears valid
  - `false` if essential components are missing
  """
  def valid_init?(opts) do
    pg_dir = Keyword.fetch!(opts, :pg_dir)
    pg_data_dir = Path.join(pg_dir, "data")

    required_paths = [
      Path.join(pg_data_dir, "PG_VERSION"),
      Path.join(pg_data_dir, "base/1"),
      Path.join(pg_data_dir, "global"),
      Path.join(pg_data_dir, "pg_hba.conf")
    ]

    Enum.all?(required_paths, &File.exists?/1)
  end

  @doc """
  Clean the PostgreSQL data directory for re-initialization.

  ## Options
  - `:pg_dir` - Base directory for PostgreSQL data (required)

  ## Returns
  - `:ok` if cleanup was successful
  - `{:error, reason}` if cleanup failed
  """
  def clean_data_dir(opts) do
    pg_dir = Keyword.fetch!(opts, :pg_dir)
    pg_data_dir = Path.join(pg_dir, "data")

    ["Cleaning PostgreSQL data directory: ", pg_data_dir] |> log(:warning)

    case File.rm_rf(pg_data_dir) do
      {:ok, _} ->
        ["PostgreSQL data directory cleaned"] |> log(:info)
        :ok

      {:error, reason, path} ->
        ["Failed to clean PostgreSQL data directory: ", inspect(reason), " at ", path]
        |> log(:error)

        {:error, reason}
    end
  end

  defp prepare_data_dir(pg_data_dir, pg_dir, run_dir) do
    log(["[initialize] pg_data_dir: ", pg_data_dir, ", run_dir: ", run_dir], :debug)
    File.mkdir_p!(pg_data_dir)
    log(["[initialize] dir created"], :debug)

    Permissions.log_permission_issues(pg_data_dir)

    [pg_data_dir]
    |> Permissions.ensure_dirs(Permissions.get_uid(), Permissions.get_gid())

    log(["[initialize] permissions set"], :debug)

    File.chmod!(pg_dir, 0o755)
    log(["[initialize] dir permissions set"], :debug)
  end

  defp run_fresh_initdb(pg_data_dir, run_dir) do
    SharedMemory.cleanup_stale(pg_data_dir)

    args =
      ["--auth-host=trust", "--auth-local=trust", "-D", pg_data_dir] ++
        Lifecycle.minimal_settings()

    ["Initializing PostgreSQL database at ", pg_data_dir, " with run_dir ", run_dir]
    |> log(:info)

    Lifecycle.run_pg("initdb", args, as_postgres_user: true, run_dir: run_dir)
  end
end
