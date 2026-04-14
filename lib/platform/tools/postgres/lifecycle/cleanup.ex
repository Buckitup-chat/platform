defmodule Platform.Tools.Postgres.Lifecycle.Cleanup do
  @moduledoc """
  PostgreSQL cleanup and stale process management.
  Handles server cleanup, stale PID removal, and IPC diagnostics.
  """
  use Toolbox.OriginLog

  alias Platform.Tools.Postgres.{Lifecycle, SharedMemory}
  alias Platform.Tools.OsPid

  @doc """
  Remove stale postmaster.pid file if the process is not running.
  """
  def remove_stale_postmaster_pid(pg_dir) do
    pid_path = Path.join([pg_dir, "data", "postmaster.pid"])

    with true <- File.exists?(pid_path),
         {:ok, contents} <- File.read(pid_path),
         [first_line | _] <- String.split(contents, "\n", trim: true),
         os_pid when not is_nil(os_pid) <- parse_os_pid(first_line) do
      if os_pid_alive?(os_pid) do
        [
          "postmaster.pid at ",
          pid_path,
          " belongs to live PID ",
          to_string(os_pid),
          ", leaving it"
        ]
        |> log(:debug)
      else
        [
          "Removing stale postmaster.pid at ",
          pid_path,
          " (PID ",
          to_string(os_pid),
          " not running)"
        ]
        |> log(:info)

        File.rm(pid_path)
      end
    end

    :ok
  end

  @doc """
  Clean up any existing PostgreSQL server before starting a new one.

  ## Options
  - `:pg_dir` - Base directory for PostgreSQL data (required)

  ## Returns
  `:ok` after cleanup attempt
  """
  def cleanup_old_server(pg_dir, opts \\ []) do
    pg_data_dir = Path.join(pg_dir, "data")
    run_dir = Lifecycle.extract_pg_run_dir(pg_dir, opts)

    force_stop_server(pg_data_dir, run_dir)
    log_ipc_info()
    SharedMemory.cleanup_stale(pg_data_dir)
    Lifecycle.ensure_run_dir(pg_dir, opts)
    remove_stale_postmaster_pid(pg_dir)

    :ok
  end

  defp force_stop_server(pg_data_dir, run_dir) do
    [
      "Attempting to stop any existing PostgreSQL server for ",
      pg_data_dir,
      " (run_dir: ",
      run_dir,
      ")"
    ]
    |> log(:info)

    {output, status} =
      Lifecycle.run_pg("pg_ctl", ["-D", pg_data_dir, "stop", "-m", "fast"],
        as_postgres_user: true,
        run_dir: run_dir
      )

    case status do
      0 -> ["Existing PostgreSQL server stopped before daemon start"] |> log(:info)
      _ -> ["pg_ctl stop exited with status ", to_string(status), ": ", output] |> log(:warning)
    end
  end

  defp log_ipc_info do
    if File.exists?("/usr/bin/lsipc") do
      {ipc_output, ipc_status} = MuonTrap.cmd("/usr/bin/lsipc", ["-m"], stderr_to_stdout: true)

      ["lsipc -m exited with status ", to_string(ipc_status), ":\n", ipc_output]
      |> log(:debug)
    end
  end

  defp parse_os_pid(nil), do: nil

  defp parse_os_pid(str) do
    str
    |> String.trim()
    |> Integer.parse()
    |> case do
      {os_pid, _} when os_pid > 0 -> os_pid
      _ -> nil
    end
  end

  defp os_pid_alive?(os_pid) when is_integer(os_pid) do
    OsPid.alive?(os_pid)
  end
end
