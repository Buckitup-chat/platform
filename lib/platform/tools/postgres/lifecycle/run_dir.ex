defmodule Platform.Tools.Postgres.Lifecycle.RunDir do
  @moduledoc """
  PostgreSQL run directory (`Chat.Storage.Unit.pg_run/1`) management.
  Handles per-device socket directory creation, permissions, and cleanup.
  """
  use Toolbox.OriginLog

  alias Platform.Tools.Postgres.Permissions

  @doc """
  Ensure the PostgreSQL run directory exists with correct permissions.

  ## Options
  - `:run_dir` - Run directory path, `Chat.Storage.Unit.pg_run/1` (required)

  ## Returns
  The run directory path.
  """
  def ensure_run_dir(opts) do
    run_dir = extract_pg_run_dir(opts)

    File.mkdir_p!(run_dir)

    parent_dir = Path.dirname(run_dir)
    File.chmod!(parent_dir, 0o755)

    [run_dir]
    |> Permissions.ensure_dirs(Permissions.get_uid(), Permissions.get_gid())

    cleanup_run_dir_files(run_dir)

    run_dir
  end

  @doc """
  Clean all files in the PostgreSQL run directory.
  """
  def cleanup_run_dir_files(run_dir) do
    with {:ok, entries} <- File.ls(run_dir),
         files = Enum.filter(entries, fn e -> !File.dir?(Path.join(run_dir, e)) end),
         true <- files != [] do
      ["Cleaning stale PG run-dir files in ", run_dir, ": ", inspect(files)] |> log(:info)

      Enum.each(files, fn entry ->
        Path.join(run_dir, entry)
        |> File.rm()
      end)
    end

    :ok
  end

  @doc """
  The PostgreSQL run directory from options. Callers derive it from the unit
  (`Chat.Storage.Unit.pg_run/1`), so nothing here parses paths.
  """
  def extract_pg_run_dir(opts), do: Keyword.fetch!(opts, :run_dir)
end
