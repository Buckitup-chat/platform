defmodule Platform.Tools.Postgres.Lifecycle.Cleanup do
  @moduledoc """
  PostgreSQL cleanup and stale process management.
  Handles server cleanup, stale PID removal, and IPC diagnostics.
  """
  use Toolbox.OriginLog

  alias Platform.Tools.OsPid
  alias Platform.Tools.Postgres.{Lifecycle, SharedMemory}

  @lsipc_path "/usr/bin/lsipc"

  # Diagnostics only — must never outlive the cleanup it is reporting on.
  @lsipc_timeout :timer.seconds(15)

  # pg_ctl gets its own deadline for the fast shutdown; the outer call timeout must
  # outlast it so pg_ctl reports the failure itself instead of being killed mid-report.
  @pg_ctl_stop_wait_seconds 30
  @pg_ctl_stop_timeout :timer.seconds(45)

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

    remove_stale_postmaster_pid(pg_dir)
    force_stop_server(pg_data_dir, run_dir)
    log_ipc_info()
    SharedMemory.cleanup_stale(pg_data_dir)
    Lifecycle.ensure_run_dir(pg_dir, opts)

    :ok
  end

  @doc """
  Remove stale postmaster.pid file if the process is not running.
  """
  def remove_stale_postmaster_pid(pg_dir) do
    pid_path = Path.join([pg_dir, "data", "postmaster.pid"])

    with {:ok, contents} <- File.read(pid_path),
         [first_line | _] <- String.split(contents, "\n", trim: true),
         {os_pid, _rest} when os_pid > 0 <- first_line |> String.trim() |> Integer.parse() do
      remove_pid_file_unless_live(pid_path, os_pid)
    end

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

    args = ["-D", pg_data_dir, "stop", "-m", "fast", "-t", to_string(@pg_ctl_stop_wait_seconds)]

    Lifecycle.run_pg("pg_ctl", args,
      as_postgres_user: true,
      run_dir: run_dir,
      timeout: @pg_ctl_stop_timeout
    )
    |> case do
      {_output, 0} ->
        ["Existing PostgreSQL server stopped before daemon start"] |> log(:info)

      {output, status} ->
        ["pg_ctl stop exited with status ", to_string(status), ": ", output] |> log(:warning)
    end
  end

  defp log_ipc_info do
    if File.exists?(@lsipc_path) do
      {ipc_output, ipc_status} =
        MuonTrap.cmd(@lsipc_path, ["-m"], stderr_to_stdout: true, timeout: @lsipc_timeout)

      ["lsipc -m exited with status ", to_string(ipc_status), ":\n", ipc_output]
      |> log(:debug)
    end
  end

  defp remove_pid_file_unless_live(pid_path, os_pid) do
    if postgres_process?(os_pid) do
      [
        "postmaster.pid at ",
        pid_path,
        " belongs to live postgres PID ",
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
        " is not a postgres process)"
      ]
      |> log(:info)

      File.rm(pid_path)
    end
  end

  defp postgres_process?(os_pid) when is_integer(os_pid) do
    OsPid.alive?(os_pid) &&
      case File.read("/proc/#{os_pid}/cmdline") do
        {:ok, cmdline} -> cmdline |> String.split(<<0>>) |> hd() == "/usr/bin/postgres"
        _ -> false
      end
  end
end
