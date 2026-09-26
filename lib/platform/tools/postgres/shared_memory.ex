defmodule Platform.Tools.Postgres.SharedMemory do
  @moduledoc """
  Handles cleanup of stale shared memory segments left by crashed PostgreSQL processes.
  Supports both POSIX shared memory (/dev/shm) and System V shared memory.
  """

  # Best-effort cleanup running inline in boot stages: bounded so a wedged IPC
  # tool degrades into a warning instead of blocking startup.
  @ipc_timeout :timer.seconds(15)

  @doc """
  Clean up stale shared memory segments associated with a PostgreSQL data directory.
  This prevents "pre-existing shared memory block is still in use" errors when
  a previous PostgreSQL instance crashed or was killed without proper cleanup.

  ## Parameters
  - `pg_data_dir` - PostgreSQL data directory path
  """
  def cleanup_stale(pg_data_dir) do
    cleanup_posix()

    if File.exists?("/usr/bin/ipcs") && File.exists?("/usr/bin/ipcrm") do
      cleanup_sysv(pg_data_dir)
    end

    :ok
  end

  @doc """
  Clean up stale POSIX shared memory segments left by crashed PostgreSQL processes.
  These are files in /dev/shm with names like "PostgreSQL.XXXXXXX".

  Only removes segments that are not currently in use by any process.
  """
  def cleanup_posix do
    shm_dir = "/dev/shm"

    with {:is_dir, true} <- {:is_dir, File.dir?(shm_dir)},
         _ = log_shm_usage(),
         {:ok, files} <- File.ls(shm_dir) do
      files
      |> Enum.filter(&String.starts_with?(&1, "PostgreSQL."))
      |> cleanup_postgres_shm_files(shm_dir)

      log_shm_usage()
    else
      {:is_dir, false} -> :ok
      {:error, reason} -> log(["Could not list /dev/shm: ", inspect(reason)], :debug)
    end

    :ok
  end

  defp cleanup_postgres_shm_files([], _shm_dir), do: :ok

  defp cleanup_postgres_shm_files(files, shm_dir) do
    log(["Found POSIX shared memory files: ", inspect(files)], :debug)

    files
    |> Enum.map(&Path.join(shm_dir, &1))
    |> Enum.each(&remove_unused_shm_file/1)
  end

  defp remove_unused_shm_file(path) do
    {in_use, holder_pids} = shm_file_in_use_with_pids(path)

    with {_, false} <- {:is_in_use, in_use},
         :ok <- File.rm(path) do
      log(["Removed stale POSIX shm: ", path], :info)
    else
      {:is_in_use, true} ->
        log(["POSIX shm in use by pids ", inspect(holder_pids), ", skipping: ", path], :debug)

      {:error, reason} ->
        log(["Could not remove POSIX shm ", path, ": ", inspect(reason)], :warning)
    end
  end

  defp log_shm_usage do
    case System.cmd("df", ["-h", "/dev/shm"], stderr_to_stdout: true) do
      {output, 0} -> log(["/dev/shm usage:\n", output], :debug)
      _ -> :ok
    end
  end

  defp shm_file_in_use_with_pids(path) do
    case File.ls("/proc") do
      {:ok, entries} ->
        entries
        |> Enum.filter(&(numeric_string?(&1) and process_uses_shm?(&1, path)))
        |> then(&{&1 != [], &1})

      _ ->
        {true, ["unknown"]}
    end
  end

  defp process_uses_shm?(pid, path),
    do: process_has_open_fd?(pid, path) || process_maps_file?(pid, path)

  defp process_has_open_fd?(pid, path) do
    fd_dir = "/proc/#{pid}/fd"

    case File.ls(fd_dir) do
      {:ok, fds} -> Enum.any?(fds, &(File.read_link(Path.join(fd_dir, &1)) == {:ok, path}))
      _ -> false
    end
  end

  defp process_maps_file?(pid, path) do
    case File.read("/proc/#{pid}/maps") do
      {:ok, content} -> String.contains?(content, path)
      _ -> false
    end
  end

  defp numeric_string?(str), do: match?({_, ""}, Integer.parse(str))

  defp cleanup_sysv(pg_data_dir) do
    case MuonTrap.cmd("/usr/bin/ipcs", ["-m"], stderr_to_stdout: true, timeout: @ipc_timeout) do
      {ipcs_output, 0} ->
        ipcs_output
        |> postgres_segments()
        |> remove_stale_segments(pg_data_dir)

      {output, status} ->
        log(["ipcs -m exited with status ", to_string(status), ": ", output], :warning)
    end
  end

  defp postgres_segments(ipcs_output) do
    ipcs_output
    |> String.split("\n")
    |> Enum.filter(&postgres_segment_line?/1)
    |> Enum.flat_map(fn line ->
      case String.split(line, ~r/\s+/, trim: true) do
        [_key, shmid | _rest] -> [shmid]
        _ -> []
      end
    end)
  end

  defp postgres_segment_line?(line),
    do: String.contains?(line, "postgres") && String.match?(line, ~r/^0x/)

  defp remove_stale_segments([], _pg_data_dir), do: :ok

  defp remove_stale_segments(segments, pg_data_dir) do
    postgres_running? = pg_data_dir |> Path.join("postmaster.pid") |> File.exists?()

    if postgres_running? do
      :ok
    else
      log(["Found potentially stale shared memory segments: ", inspect(segments)], :debug)

      Enum.each(segments, &remove_segment/1)
    end
  end

  defp remove_segment(shmid) do
    case MuonTrap.cmd("/usr/bin/ipcrm", ["-m", shmid],
           stderr_to_stdout: true,
           timeout: @ipc_timeout
         ) do
      {_output, 0} ->
        log(["Removed stale shared memory segment: ", shmid], :info)

      {output, _status} ->
        log(["Could not remove shared memory segment ", shmid, ": ", output], :debug)
    end
  end

  defp log(msg, level), do: Platform.Log.postgres_log(msg, level)
end
