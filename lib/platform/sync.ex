defmodule Platform.Sync do
  @moduledoc """
    Introduces DB syncronisation logic

    Initial DB - stored on SD card. Is used when no external USB attached on boot time
    Main DB - stored on external USB that attached during boot time
    Backup DB - extarnal USB attached after bootup. Is used for one time syncronization of its content with main(or initial) one 
  """

  require Logger

  alias Chat.Db
  alias Platform.Leds
  alias Platform.Tools.Fsck
  alias Platform.Tools.Mount

  @doc "One time sync with backup DB"
  def sync(nil), do: :nothing

  def sync(device) do
    device
    |> recover_fs_if_errors()
    |> mount()
    |> tap(fn path ->
      path
      |> find_or_create_db()
      |> dump_my_data()
      |> get_new_data()
      |> stop_db()
    end)
    |> Mount.unmount()
  end

  @doc "Switches from initial to main one"
  def switch_storage_to(device) do
    device
    |> recover_fs_if_errors()
    |> mount_on_storage_path()
    |> start_new_db()
    |> copy_data_to_new()
    |> switch_on_new()
    |> stop_initial_db()
  end

  def switch_safe do
    path = Db.file_path()
    db_pid = Db.db()

    if path != CubDB.data_dir(db_pid) do
      {:ok, safe_db} = CubDB.start(path)

      safe_db
      |> Db.swap_pid()
      |> CubDB.stop()
    end
  end

  defp recover_fs_if_errors(device) do
    Fsck.vfat(device)
    device
  end

  defp mount_on_storage_path(device) do
    "/root/storage"
    |> tap(&File.mkdir_p!/1)
    |> tap(fn path ->
      {_, 0} = Mount.mount_at_path(device, path)
    end)
  end

  defp start_new_db(device_root) do
    device_root
    |> main_db_path()
    |> start_db()
  end

  defp copy_data_to_new(pid) do
    dump_my_data(pid)
  end

  defp switch_on_new(new_pid) do
    Db.swap_pid(new_pid)
  end

  defp stop_initial_db(pid) do
    stop_db(pid)
  end

  defp find_or_create_db(device_root) do
    device_root
    |> backup_path()
    |> start_db()
  end

  defp dump_my_data(other_db) do
    Leds.blink_write()
    Db.copy_data(Db.db(), other_db)
    Leds.blink_done()

    other_db
  end

  defp get_new_data(other_db) do
    Leds.blink_read()
    Db.copy_data(other_db, Db.db())
    Leds.blink_done()

    other_db
  end

  defp backup_path(prefix) do
    [prefix, "bdb", Db.version_path()]
    |> Path.join()
    |> tap(&File.mkdir_p!/1)
  end

  defp main_db_path(prefix) do
    [prefix, "main_db", Db.version_path()]
    |> Path.join()
    |> tap(&File.mkdir_p!/1)
  end

  defp start_db(path) do
    {:ok, pid} = CubDB.start_link(path)

    pid
  end

  defp stop_db(other_db) do
    CubDB.stop(other_db)
  end

  defp mount(device) do
    path = Path.join(["/root", "media", device])
    File.mkdir_p!(path)
    {_, 0} = Mount.mount_at_path(device, path)

    path
  end
end
