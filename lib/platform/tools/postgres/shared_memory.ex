defmodule Platform.Tools.Postgres.SharedMemory do
  @moduledoc """
  Handles cleanup of stale shared memory segments left by crashed PostgreSQL processes.
  Supports both POSIX shared memory (/dev/shm) and System V shared memory.
  """

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

    with {_, true} <- {:is_dir, File.dir?(shm_dir)},
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

    Enum.each(files, fn file ->
      path = Path.join(shm_dir, file)
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
    end)
  end

  defp cleanup_sysv(pg_data_dir) do
    {ipcs_output, 0} = MuonTrap.cmd("/usr/bin/ipcs", ["-m"], stderr_to_stdout: true)

    stale_segments =
      ipcs_output
      |> String.split("\n")
      |> Enum.filter(fn line ->
        String.contains?(line, "postgres") && String.match?(line, ~r/^0x/)
      end)
      |> Enum.map(fn line ->
        case String.split(line, ~r/\s+/, trim: true) do
          [_key, shmid | _rest] -> shmid
          _ -> nil
        end
      end)
      |> Enum.reject(&is_nil/1)

    postmaster_pid_file = Path.join(pg_data_dir, "postmaster.pid")

    if !File.exists?(postmaster_pid_file) && stale_segments != [] do
      log(["Found potentially stale shared memory segments: ", inspect(stale_segments)], :debug)

      Enum.each(stale_segments, fn shmid ->
        {rm_output, rm_status} =
          MuonTrap.cmd("/usr/bin/ipcrm", ["-m", shmid], stderr_to_stdout: true)

        if rm_status == 0 do
          log(["Removed stale shared memory segment: ", shmid], :info)
        else
          log(["Could not remove shared memory segment ", shmid, ": ", rm_output], :debug)
        end
      end)
    end
  end

  defp log_shm_usage do
    case System.cmd("df", ["-h", "/dev/shm"], stderr_to_stdout: true) do
      {output, 0} -> log(["/dev/shm usage:\n", output], :debug)
      _ -> :ok
    end
  end

  defp shm_file_in_use_with_pids(path) do
    with {:ok, entries} <- File.ls("/proc") do
      pids =
        entries
        |> Enum.filter(&numeric_string?/1)
        |> Enum.filter(fn pid -> process_uses_shm?(pid, path) end)

      {pids != [], pids}
    else
      _ -> {true, ["unknown"]}
    end
  end

  defp process_uses_shm?(pid, path) do
    fd_dir = "/proc/#{pid}/fd"

    fd_match =
      case File.ls(fd_dir) do
        {:ok, fds} ->
          Enum.any?(fds, fn fd ->
            case File.read_link(Path.join(fd_dir, fd)) do
              {:ok, target} -> target == path
              _ -> false
            end
          end)

        _ ->
          false
      end

    maps_file = "/proc/#{pid}/maps"

    maps_match =
      case File.read(maps_file) do
        {:ok, content} -> String.contains?(content, path)
        _ -> false
      end

    fd_match || maps_match
  end

  defp numeric_string?(str) do
    case Integer.parse(str) do
      {_, ""} -> true
      _ -> false
    end
  end

  defp log(msg, level), do: Platform.Log.postgres_log(msg, level)
end
