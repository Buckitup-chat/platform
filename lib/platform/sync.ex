defmodule Platform.Sync do
  @moduledoc """
    Introduces DB synchronisation logic

    Initial DB - stored on SD card. Is used when no external USB attached on boot time
    Main DB - stored on external USB that attached during boot time
    Backup DB - external USB attached after bootup. Is used for one time synchronization of its content with main (or initial) one
  """

  require Logger

  alias Chat.Db
  alias Chat.Db.Pids
  alias Chat.Ordering
  alias Platform.Leds
  alias Platform.Storage.Transfer
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
      |> dump_my_data_to_backup()
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
    |> dump_my_data_to_internal()
    |> tap(fn _ -> Logger.info("[platform-sync] Data moved to external storage") end)
    |> switch_on_new()
    |> stop_initial_db()
  end

  @doc "Switch to initial db"
  def switch_safe do
    path = Db.file_path()
    db_pid = Db.db()

    if path != CubDB.data_dir(db_pid) do
      {:ok, safe_db} = CubDB.start(path, auto_file_sync: false)
      file_dir = Db.file_db_path()

      %Pids{main: safe_db, file: file_dir}
      |> Db.swap_pid()
      |> stop_db()
      |> tap(fn _ -> Ordering.reset() end)
    end
  end

  def dump_my_data_to_internal(other_db_pids) do
    Leds.blink_write()
    # Db.copy_data(Db.db(), other_db_pids.main)
    "[platform-replicate] going to dump data to internal #{inspect(other_db_pids)}"
    |> Logger.warn()

    Transfer.one_way(Db.db(), other_db_pids.main)
    "[platform-replicate] Data dumped. Copying files" |> Logger.warn()
    Db.copy_files(Db.file_dir(), other_db_pids.file)
    "[platform-replicate] Files copied" |> Logger.warn()
    # Db.copy_data(Db.file_db(), other_db_pids.file)
    Leds.blink_done()

    other_db_pids
  rescue
    _ -> other_db_pids
  end

  def dump_my_data_to_backup(other_db_pids) do
    Leds.blink_write()
    # Db.copy_data(Db.db(), other_db_pids.main)
    Transfer.one_way(Db.db(), other_db_pids.main)
    Db.copy_files(Db.file_dir(), other_db_pids.file)
    # Db.copy_data(Db.file_db(), other_db_pids.file)
    Leds.blink_done()

    other_db_pids
  rescue
    _ -> other_db_pids
  end

  defp recover_fs_if_errors(device) do
    Leds.blink_read()
    Fsck.vfat(device)
    Leds.blink_done()
    Logger.info("[platform-sync] #{device} health checked")
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

  defp switch_on_new(new_pids) do
    Db.swap_pid(new_pids)
    |> tap(fn _ -> Ordering.reset() end)
  end

  defp stop_initial_db(pids) do
    stop_db(pids)
  end

  defp find_or_create_db(device_root) do
    device_root
    |> backup_path()
    |> start_db()
  end

  defp get_new_data(%Pids{} = other_pids) do
    Leds.blink_read()
    # Db.copy_data(other_pids.main, Db.db())
    Transfer.one_way(other_pids.main, Db.db())
    Db.copy_files(other_pids.file, Db.file_dir())
    # Db.copy_data(other_pids.file, Db.file_db())
    Leds.blink_done()

    Ordering.reset()
    other_pids
  rescue
    _ ->
      Ordering.reset()
      other_pids
  end

  defp backup_path(prefix) do
    main =
      [prefix, "bdb", Db.version_path()]
      |> Path.join()
      |> tap(&File.mkdir_p!/1)

    file =
      [prefix, "bdb", "files"]
      |> Path.join()
      |> tap(&File.mkdir_p!/1)

    {main, file}
  end

  defp main_db_path(prefix) do
    main =
      [prefix, "main_db", Db.version_path()]
      |> Path.join()
      |> tap(&File.mkdir_p!/1)

    file =
      [prefix, "main_db", "files"]
      |> Path.join()
      |> tap(&File.mkdir_p!/1)

    {main, file}
  end

  defp start_db({path, file_path}) do
    {:ok, pid} = CubDB.start_link(path, auto_file_sync: false)
    file_dir = file_path

    %Pids{main: pid, file: file_dir}
  end

  defp stop_db(%Pids{} = pids) do
    CubDB.file_sync(pids.main)
    CubDB.stop(pids.main)
  end

  defp mount(device) do
    path = Path.join(["/root", "media", device])
    File.mkdir_p!(path)
    {_, 0} = Mount.mount_at_path(device, path)

    path
  end
end
