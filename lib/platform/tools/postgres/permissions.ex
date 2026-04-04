defmodule Platform.Tools.Postgres.Permissions do
  use Toolbox.OriginLog

  @moduledoc """
  Handles PostgreSQL directory and file permissions.
  Ensures proper ownership (postgres user/group) and access modes.
  """

  @postgres_user "postgres"

  @doc """
  Get the UID of the postgres system user.
  """
  def get_uid do
    {uid_str, 0} = MuonTrap.cmd("id", ["-u", @postgres_user], stderr_to_stdout: true)
    String.trim(uid_str) |> String.to_integer()
  end

  @doc """
  Get the GID of the postgres system group.
  """
  def get_gid do
    {gid_str, 0} = MuonTrap.cmd("id", ["-g", @postgres_user], stderr_to_stdout: true)
    String.trim(gid_str) |> String.to_integer()
  end

  @doc """
  Ensure a path is accessible by the postgres user.
  Sets ownership to postgres:postgres with appropriate permissions.
  """
  def make_accessible(path) do
    [path] |> ensure_dirs(get_uid(), get_gid())
  end

  @doc """
  Recursively ensure directories have correct permissions.
  Directories get 0o700, files get 0o600.
  Uses find command for quick check - skips if permissions already correct.
  """
  def ensure_dirs([], _uid, _gid), do: :ok

  def ensure_dirs(dirs, uid, gid) when is_list(dirs) do
    if permissions_correct?(dirs) do
      log(["[permissions] already correct, skipping fix"], :debug)
      :ok
    else
      do_ensure_dirs(dirs, uid, gid)
    end
  end

  defp do_ensure_dirs([], _uid, _gid), do: :ok

  defp do_ensure_dirs(dirs, uid, gid) when is_list(dirs) do
    dirs
    |> Enum.flat_map(fn dir ->
      set(dir, uid, gid, 0o700)

      case File.ls(dir) do
        {:ok, filelist} ->
          Enum.reduce(filelist, [], fn file_or_dir, acc ->
            path = Path.join(dir, file_or_dir)

            if File.dir?(path) do
              [path | acc]
            else
              set(path, uid, gid, 0o600)
              acc
            end
          end)

        {:error, reason} ->
          log(["Failed to list directory ", dir, ": ", inspect(reason)], :error)
          []
      end
    end)
    |> do_ensure_dirs(uid, gid)
  end

  defp set(path, uid, gid, mod) do
    with {:ok, %{mode: f_mod, uid: f_uid, gid: f_gid}} <- File.stat(path),
         change_uid? <- f_uid != uid,
         change_gid? <- f_gid != gid,
         change_mod? <- rem(f_mod, 0o1000) != mod,
         true <- change_uid? || change_gid? || change_mod?,
         log(
           [
             path,
             " ",
             inspect({f_uid, f_gid, f_mod |> Integer.to_string(8)}),
             " -> ",
             inspect({uid, gid, mod |> Integer.to_string(8)})
           ],
           :debug
         ) do
      track(change_uid?, fn -> File.chown!(path, uid) end, [path, " own"])
      track(change_gid?, fn -> File.chgrp!(path, gid) end, [path, " grp"])
      track(change_mod?, fn -> File.chmod!(path, mod) end, [path, " mod"])
    end
  end

  defp track(predicate, fun, msg) do
    if predicate do
      :timer.tc(fun)
      log([msg], :debug)
    end
  end

  @doc """
  Log permission issues found in a directory for debugging.
  Uses find commands to detect files/dirs with wrong ownership or permissions.
  """
  def log_permission_issues(dir) do
    log(["[permission check] ", dir], :debug)

    find_and_log(dir, ~w[! -user postgres -print], "wrong_uid_list")
    find_and_log(dir, ~w[! -group postgres -print], "wrong_gid_list")
    find_and_log(dir, ~w[-type f ! -perm 600 -print], "wrong_files")
    find_and_log(dir, ~w[-type d ! -perm 700 -print], "wrong_dirs")

    :ok
  end

  defp find_and_log(dir, args, label) do
    case System.cmd("find", [dir | args], stderr_to_stdout: true) do
      {output, 0} ->
        log(["[permission check] ", label, ": ", output], :debug)

      {output, code} ->
        log(
          ["[permission check] ", label, " failed (exit ", to_string(code), "): ", output],
          :warning
        )
    end
  end

  @args ~w[( ! -user] ++
          [@postgres_user] ++ ~w[-o ! -group] ++ [@postgres_user] ++ ~w[) -print -quit]
  defp permissions_correct?(dirs) do
    Enum.all?(dirs, fn dir ->
      case System.cmd("find", [dir | @args]) do
        {"", 0} -> true
        _ -> false
      end
    end)
  end
end
