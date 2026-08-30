defmodule Platform.Tools.Postgres.CrashLogs do
  @moduledoc """
  Captures PostgreSQL crash evidence — the tail of the newest server log and any
  leftover `postmaster.pid` — ahead of `Platform.Tools.Postgres.Lifecycle.Cleanup`
  clearing the data directory.

  Reads storage that may itself be the thing failing, so callers must run this off
  their message loop. A missing directory or an unreadable file is a normal
  outcome here, not an error: it simply leaves no evidence behind.
  """
  use Toolbox.OriginLog

  @tail_lines 50

  @doc "Log crash evidence for the PostgreSQL instance rooted at `pg_dir`."
  def capture(pg_dir) do
    pg_data_dir = Path.join(pg_dir, "data")

    pg_data_dir |> Path.join("log") |> log_newest_log_file()
    pg_data_dir |> Path.join("postmaster.pid") |> log_leftover_pid_file()

    :ok
  end

  defp log_newest_log_file(log_dir) do
    with {:ok, [_ | _] = files} <- File.ls(log_dir),
         newest = Enum.max(files),
         {:ok, content} <- File.read(Path.join(log_dir, newest)) do
      ["PostgreSQL log (", newest, "):\n", tail(content)] |> log(:warning)
    end
  end

  defp tail(content) do
    content
    |> String.split("\n")
    |> Enum.take(-@tail_lines)
    |> Enum.join("\n")
  end

  defp log_leftover_pid_file(pid_path) do
    with {:ok, content} <- File.read(pid_path) do
      ["Stale postmaster.pid found:\n", content] |> log(:warning)
    end
  end
end
