defmodule Platform.Storage.Logic do
  @moduledoc "Storage logic"

  require Logger

  alias Chat.Db
  alias Chat.Db.Common
  alias Chat.Db.Copying
  alias Chat.Db.Maintenance
  alias Chat.Db.Switching
  alias Platform.Storage.Device

  def on_new(devices) do
    db_mode = get_db_mode()

    case {db_mode, devices} do
      {_, []} ->
        :skip

      {:internal, [device]} ->
        switch_internal_to_main(device)

      {:main, devices} ->
        make_backups_to(devices)

      {_, devices} ->
        Logger.warn(
          "[platform-storage] Cannot decide what to do with devices: #{inspect(devices)}"
        )
    end
  end

  def replicate_main_to_internal do
    case get_db_mode() do
      :main_to_internal -> do_replicate_to_internal()
      :main -> do_replicate_to_internal()
      _ -> :ignored
    end
  end

  def on_remove(removed, connected) do
    removed |> handle_removed_devices()
    connected |> handle_devices_left_connected()
  end

  def unmount_main do
    if get_db_mode() == :main do
      # DynamicSupervisor.terminate_child(
      #   Platform.MainDbSupervisor,
      #   Platform.App.Db.MainDbSupervisor |> Process.whereis()
      # )

      switch_main_to_internal()

      device =
        Chat.Db.MainDb
        |> CubDB.data_dir()
        |> Maintenance.path_to_device()

      DynamicSupervisor.terminate_child(
        Platform.MainDbSupervisor,
        Chat.Db.MainDbSupervisor |> Process.whereis()
      )

      Device.unmount(device)

      :unmounted
    else
      :ignored
    end
  end

  def info do
    %{
      db: get_db_mode(),
      flags: Common.get_chat_db_env(:flags),
      writable: Common.get_chat_db_env(:writable),
      budget: Common.get_chat_db_env(:write_budget)
    }
  end

  # Device handling

  defp handle_removed_devices(devices) do
    devices
    |> Enum.each(fn device ->
      if is_main_device?(device) do
        # DynamicSupervisor.terminate_child(
        #   Platform.MainDbSupervisor,
        #   Platform.App.Db.MainDbSupervisor |> Process.whereis()
        # )

        switch_back_to_internal()
        Device.unmount(device)

      else
        Device.unmount(device)
      end
    end)
  end

  defp handle_devices_left_connected(devices) do
    case {get_db_mode(), devices} do
      {:internal, [device]} -> switch_internal_to_main(device)
      _ -> :skip
    end
  end

  # Implementations

  defp switch_internal_to_main(device) do
    # Platform.MainDbSupervisor
    # |> DynamicSupervisor.start_child({Platform.App.Db.MainDbSupervisor, [device]})

    # |> inspect()
    # |> Logger.error()

    # Process.info(self(), :current_stacktrace)
    # |> inspect(pretty: true)
    # |> Logger.warn()

    set_db_mode(:internal_to_main)

    case sync_and_switch_on_main(device) do
      :ok ->
        set_db_mode(:main)
        start_replicating_on_internal()

        "[platform-storage] Switched to main" |> Logger.info()

      {:error, e} ->
        set_db_mode(:internal)
        log(e)
    end
  end

  defp switch_back_to_internal do
    internal = Chat.Db.InternalDb

    set_db_mode(:main_to_internal)
    stop_replicating_on_internal()

    Switching.set_default(internal)
    "[platform-storage] Switched to internal" |> Logger.info()

    set_db_mode(:internal)
  end

  defp switch_main_to_internal do
    set_db_mode(:main_to_internal)

    # replicate_main_to_internal()
    # switch_back_to_internal()

    Chat.Db.db()
    |> CubDB.data_dir()
    |> Maintenance.path_to_device()
    |> tap(fn _ ->
      replicate_main_to_internal()
      switch_back_to_internal()
    end)
  end

  defp do_replicate_to_internal do
    internal = Chat.Db.InternalDb
    main = Chat.Db.MainDb

    set_db_flag(replication: true)
    "[platform-storage] Replicating to internal" |> Logger.info()

    Switching.mirror(main, internal)
    Copying.await_copied(main, internal)

    "[platform-storage] Replicated to internal" |> Logger.info()
    set_db_flag(replication: false)
  end

  defp make_backups_to([device]) do
    # Platform.BackupDbSupervisor
    # |> DynamicSupervisor.start_child({Chat.Db.BackupDbSupervisor, device})

    set_db_flag(backup: true)
    "[platform-storage] Syncing to device #{device}" |> Logger.info()

    start_backup_db(device)
    Leds.blink_read()
    Copying.await_copied(Chat.Db.BackupDb, Db.db())
    Leds.blink_write()
    Copying.await_copied(Db.db(), Chat.Db.BackupDb)
    Leds.blink_done()
    Chat.Ordering.reset()
    stop_backup_db()

    "[platform-storage] Synced to device #{device}" |> Logger.info()
    set_db_flag(backup: false)
  end

  defp sync_and_switch_on_main(device) do
    internal = Chat.Db.InternalDb
    main = Chat.Db.MainDb

    start_main_db(device)
    Switching.mirror(internal, main)
    Copying.await_copied(internal, main)
    Switching.set_default(main)
    Process.sleep(500)
    Switching.mirror(main, internal)

    Logger.info("[platform-sync] Data moved to external storage")

    :ok
  rescue
    e -> {:error, e}
  end

  defp start_main_db(device) do
    device
    |> Device.heal()
    |> Device.mount_on("/root/storage")
    |> then(fn path ->
      [path, "main_db", Db.version_path()]
      |> Path.join()
      |> tap(&File.mkdir_p!/1)
    end)
    |> then(fn full_path ->
      Platform.MainDbSupervisor
      |> DynamicSupervisor.start_child({Chat.Db.MainDbSupervisor, full_path})
    end)
  end

  defp start_backup_db(device) do
    device
    |> Device.heal()
    |> Device.mount_on("/root/media")
    |> then(fn path ->
      [path, "bdb", Db.version_path()]
      |> Path.join()
      |> tap(&File.mkdir_p!/1)
    end)
    |> then(fn full_path ->
      Platform.BackupDbSupervisor
      |> DynamicSupervisor.start_child({Chat.Db.BackupDbSupervisor, full_path})
    end)
  end

  defp stop_backup_db do
    device =
      Chat.Db.MainDb
      |> CubDB.data_dir()
      |> Maintenance.path_to_device()

    DynamicSupervisor.terminate_child(
      Platform.BackupDbSupervisor,
      Chat.Db.BackupDbSupervisor |> Process.whereis()
    )

    Device.unmount(device)
  end

  # defp log(error) do
  #   "[platform-storage] error: #{inspect(error, pretty: true)}"
  #   |> Logger.error()
  # end

  defp start_replicating_on_internal, do: MainReplicator.start()
  defp stop_replicating_on_internal, do: MainReplicator.stop()

  # Device support functions

  defp is_main_device?(device) do
    with db_pid <- Db.db(),
         true <- Process.alive?(db_pid),
         db_path <- CubDB.data_dir(db_pid),
         db_device <- Maintenance.path_to_device(db_path) do
      db_device == "/dev/#{device}"
    else
      _ ->
        "[platform-storage] DB process dead" |> Logger.warn()
        true
    end
  rescue
    e ->
      "[platform-storage] Exception checking main DB : #{inspect(e)}" |> Logger.error()
      true
  end

  # DB functions

  defp get_db_mode, do: Common.get_chat_db_env(:mode)
  # defp set_db_mode(mode), do: Common.put_chat_db_env(:mode, mode)

  defp set_db_flag([]), do: Common.put_chat_db_env(:flags, [])

  defp set_db_flag(flags) do
    Common.get_chat_db_env(:flags)
    |> Keyword.merge(flags)
    |> then(&Common.put_chat_db_env(:flags, &1))
  end
end
