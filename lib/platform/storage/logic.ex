defmodule Platform.Storage.Logic do
  @moduledoc "Storage logic"

  require Logger

  alias Chat.Db
  alias Chat.Db.Common
  alias Chat.Db.Maintenance
  alias Chat.Db.Pids
  alias Chat.Db.WritableUpdater
  alias Platform.Storage.MainReplicator
  alias Platform.Sync
  alias Platform.Tools.Mount

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

  def on_remove(removed, connected) do
    db_mode = get_db_mode()

    case {db_mode, connected} do
      {:internal, [device]} -> switch_internal_to_main(device)
      _ -> :skip
    end

    removed
    |> Enum.each(fn device ->
      if is_main_device?(device) do
        switch_back_to_internal()
        umount_removed_device(device)
      end
    end)
  end

  def unmount_main do
    if get_db_mode() == :main do
      Common.put_chat_db_env(:writable, :no)
      Common.put_chat_db_env(:mode, :internal_to_main)

      Chat.Db.db()
      |> CubDB.data_dir()
      |> Maintenance.path_to_device()
      |> tap(fn _ ->
        replicate_main_to_internal()
        switch_back_to_internal()
      end)
      |> umount_removed_device()

      :unmounted
    else
      :ignored
    end
  end

  def replicate_main_to_internal do
    db_mode = get_db_mode()

    case db_mode do
      :main ->
        "[platform-storage] Replicating to internal" |> Logger.info()

        start_internal_db_pids()
        |> replicate_main()
        |> stop_db_pids()

        "[platform-storage] Replicated to internal" |> Logger.info()

      _ ->
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

  # Implementations

  defp switch_internal_to_main(device) do
    set_db_write_budget_to(0)
    set_db_mode(:internal_to_main)

    case sync_and_switch_on(device) do
      :ok ->
        check_write_budget()
        set_db_mode(:main)
        start_replicating_on_internal()

        "[platform-storage] Switched to main" |> Logger.info()

      {:error, e} ->
        check_write_budget()
        set_db_mode(:internal)
        log(e)
    end
  end

  defp switch_back_to_internal do
    set_db_write_budget_to(0)
    set_db_mode(:main_to_internal)
    stop_replicating_on_internal()

    switch_db_on_internal()
    "[platform-storage] Switched to internal" |> Logger.info()

    check_write_budget()
    set_db_mode(:internal)
  end

  defp make_backups_to(devices) do
    set_db_flag(backup: true)

    devices
    |> Enum.each(&sync_to/1)

    set_db_flag(backup: false)
  end

  defp replicate_main(db_pids) do
    db_pids
    |> tap(fn _ -> set_db_flag(replication: true) end)
    |> Sync.dump_my_data_to_internal()
    |> tap(fn _ -> set_db_flag(replication: false) end)
  end

  defp sync_to(device) do
    "[platform-storage] Syncing to device #{device}" |> Logger.info()

    Sync.sync(device)
    |> tap(fn _ ->
      "[platform-storage] Synced to device #{device}" |> Logger.info()
    end)
  end

  defp sync_and_switch_on(device) do
    Sync.switch_storage_to(device)

    :ok
  rescue
    e -> {:error, e}
  end

  defp switch_db_on_internal do
    start_internal_db_pids()
    |> Db.swap_pid()
    |> stop_db_pids()
  end

  defp start_internal_db_pids do
    main_path = Db.file_path()
    file_dir = Db.file_db_path()

    {:ok, data_pid} = CubDB.start(main_path, auto_file_sync: true)

    %Pids{main: data_pid, file: file_dir}
  end

  defp log(error) do
    "[platform-storage] error: #{inspect(error, pretty: true)}"
    |> Logger.error()
  end

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

  defp umount_removed_device(device) do
    "/dev/#{device}"
    |> Maintenance.device_to_path()
    |> Mount.unmount()
  end

  defp check_write_budget, do: WritableUpdater.force_check()

  defp stop_db_pids(pids) do
    [pids.main]
    |> Enum.each(fn pid ->
      if Process.alive?(pid) do
        CubDB.stop(pid)
      end
    end)
  end

  # DB functions

  defp get_db_mode, do: Common.get_chat_db_env(:mode)
  defp set_db_mode(mode), do: Common.put_chat_db_env(:mode, mode)

  defp set_db_write_budget_to(amount), do: Common.put_chat_db_env(:write_budget, amount)

  defp set_db_flag([]), do: Common.put_chat_db_env(:flags, [])

  defp set_db_flag(flags) do
    Common.get_chat_db_env(:flags)
    |> Keyword.merge(flags)
    |> then(&Common.put_chat_db_env(:flags, &1))
  end
end
