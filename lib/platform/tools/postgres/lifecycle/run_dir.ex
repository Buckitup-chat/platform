defmodule Platform.Tools.Postgres.Lifecycle.RunDir do
  @moduledoc """
  PostgreSQL run directory (`/tmp/pg_run/<device>`) management.
  Handles per-device socket directory creation, permissions, and cleanup.
  """
  use Toolbox.OriginLog

  alias Platform.Tools.Postgres.Permissions

  @pg_run_dir "/tmp/pg_run"
  @media_mount_path Application.compile_env(:platform, :mount_path_media)
  @media_prefix @media_mount_path |> String.split("/", trim: true)

  @doc """
  Ensure the PostgreSQL run directory exists with correct permissions.

  ## Options
  - `:pg_dir` - Base directory for PostgreSQL data (required)
  - `:run_dir` - Override run directory path (optional)
  - `:device` - Device name for run directory (optional)

  ## Returns
  The run directory path.
  """
  def ensure_run_dir(pg_dir, opts \\ []) do
    run_dir = extract_pg_run_dir(pg_dir, opts)

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
  Extract the PostgreSQL run directory path from options.
  """
  def extract_pg_run_dir(pg_dir, opts \\ []) do
    cond do
      run_dir = Keyword.get(opts, :run_dir) ->
        run_dir

      device = Keyword.get(opts, :device) ->
        Path.join(@pg_run_dir, device)

      true ->
        device =
          case String.split(pg_dir, "/", trim: true) do
            @media_prefix ++ [device | _] -> device
            _ -> "internal"
          end

        Path.join(@pg_run_dir, device)
    end
  end
end
