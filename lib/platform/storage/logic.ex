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
    "[platform] [storage] new device on #{db_mode} : #{inspect(devices)}" |> Logger.debug()

    case {db_mode, devices} do
      {_, []} ->
        :skip

      {:internal, [device]} ->
        switch_internal_to_main(device)

      {:main, devices} ->
        start_media_supervisor(devices)

      {_, devices} ->
        "[platform] [storage] Cannot decide devices: #{inspect(devices)}" |> Logger.warn()
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
      # todo: find main supervisor started
      DynamicSupervisor.terminate_child(
        Platform.MainDbSupervisor,
        Platform.App.Db.MainDbSupervisor |> Process.whereis()
      )

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
        DynamicSupervisor.terminate_child(
          Platform.MainDbSupervisor,
          Platform.App.Db.MainDbSupervisor |> Process.whereis()
        )
      else
        "[platform] [storage] remove #{inspect(device)}" |> Logger.debug()
        Device.unmount(device)

        case Process.whereis(Platform.App.Media.Supervisor) do
          nil ->
            nil

          pid ->
            DynamicSupervisor.terminate_child(Platform.App.Media.DynamicSupervisor, pid)
        end
      end
    end)
  end

  defp handle_devices_left_connected(devices) do
    {devices_in_use, unused_devices} =
      devices
      |> Enum.split_with(fn device ->
        if String.starts_with?(device, "/dev/") do
          device
        else
          "/dev/" <> device
        end
        |> Maintenance.device_to_path()
      end)

    case {get_db_mode(), unused_devices, devices_in_use} do
      {:internal, [device], _devices_in_use} -> switch_internal_to_main(device)
      # {:internal, [], [device]} -> switch_backup_to_main(device)
      _ -> :skip
    end
  end

  # Implementations

  defp switch_internal_to_main(device) do
    Platform.MainDbSupervisor
    |> DynamicSupervisor.start_child({Platform.App.Db.MainDbSupervisor, [device]})
  end


  defp do_replicate_to_internal do
    internal = Chat.Db.InternalDb
    main = Chat.Db.MainDb
    backup = Chat.Db.BackupDb

    set_db_flag(replication: true)
    "[platform] [storage] Replicating to internal" |> Logger.info()

    case Process.whereis(backup) do
      nil ->
        Logger.warn("setting mirror: #{inspect(internal)}")
        Switching.mirror(main, internal)
        Copying.await_copied(main, internal)

      _pid ->
        Logger.warn("setting mirrors: #{inspect([internal, backup])}")
        Switching.mirror(main, [internal, backup])
        Copying.await_copied(main, internal)
        # TODO: continious backup need a way for new changes
        # Copying.await_copied(main, backup)
    end

    "[platform] [storage] Replicated to internal" |> Logger.info()
    set_db_flag(replication: false)
  end

  defp start_media_supervisor([device]) do
    Platform.App.Media.DynamicSupervisor
    |> DynamicSupervisor.start_child({Platform.App.Media.Supervisor, [device]})
    |> tap(fn x -> Logger.debug("media supervisor start result: #{inspect(x)}") end)
  end

  # Device support functions

  defp is_main_device?(device) do
    with db_pid <- Db.db() |> Process.whereis(),
         true <- Process.alive?(db_pid),
         db_path <- CubDB.data_dir(db_pid),
         db_device <- Maintenance.path_to_device(db_path) do
      db_device == "/dev/#{device}"
    else
      _ ->
        "[platform] [storage] DB process dead" |> Logger.warn()
        true
    end
  rescue
    e ->
      "[platform] [storage] Exception checking main DB : #{inspect(e)}" |> Logger.error()
      true
  end

  # DB functions

  defp get_db_mode, do: Common.get_chat_db_env(:mode)

  defp set_db_flag(flags) do
    Common.get_chat_db_env(:flags)
    |> Keyword.merge(flags)
    |> then(&Common.put_chat_db_env(:flags, &1))
  end
end
