defmodule Platform.UsbDrives.Decider do
  @moduledoc "Decides scenario"

  use GenServer

  require Logger

  alias Platform.Tools.Mount
  alias Platform.Tools.Mkfs

  alias Chat.Admin.MediaSettings
  alias Chat.AdminRoom
  alias Chat.Sync.UsbDriveDumpRoom
  alias Platform.App.Drive.BackupDbSupervisor
  alias Platform.App.Drive.MainDbSupervisor
  alias Platform.App.Drive.CargoSyncSupervisor
  alias Platform.App.Drive.OnlinersSyncSupervisor
  alias Platform.App.Drive.UsbDriveDumpSupervisor
  alias Platform.Storage.DriveIndication

  @supervisor_map %{
    backup: BackupDbSupervisor,
    cargo: CargoSyncSupervisor,
    onliners: OnlinersSyncSupervisor
  }

  def start_link(args) do
    GenServer.start_link(__MODULE__, args, [])
  end

  @impl true
  def init([device, opts]) do
    mount_path = Keyword.fetch!(opts, :mounted)
    next_opts = Keyword.fetch!(opts, :next)
    next_supervisor = Keyword.fetch!(next_opts, :under)

    %{
      device: device,
      at: mount_path,
      next_supervisor: next_supervisor
    }
    |> then(&{:ok, &1, {:continue, :decide}})
  end

  @impl true
  def handle_continue(:decide, %{device: device, at: path, next_supervisor: supervisor} = state) do
    scenario = decide(path)

    if scenario != CargoSyncSupervisor do
      DriveIndication.drive_reset()
    end

    if scenario do
      start(scenario, supervisor, device, path)
    end

    {:noreply, state}
  end

  defp decide(path) do
    cond do
      UsbDriveDumpRoom.get() -> UsbDriveDumpSupervisor
      File.exists?("#{path}/cargo_db") -> CargoSyncSupervisor
      File.exists?("#{path}/onliners_db") -> OnlinersSyncSupervisor
      File.exists?("#{path}/backup_db") -> BackupDbSupervisor
      File.exists?("#{path}/main_db") -> (on_internal_db?() && MainDbSupervisor) || nil
      create_first_main?() -> MainDbSupervisor |> may_optimimize_if_blank(path)
      true -> default_scenario() |> may_optimimize_if_blank(path)
    end
  end

  defp may_optimimize_if_blank(scenario, path) do
    if drive_blank?(path) and should_optimize?() do
      optimize_fs(path)
    end

    scenario
  end

  defp on_internal_db? do
    Chat.Db.Common.get_chat_db_env(:mode) == :internal
  end

  defp create_first_main? do
    %MediaSettings{main: create_main?} = AdminRoom.get_media_settings()

    create_main? and on_internal_db?()
  end

  defp should_optimize? do
    %MediaSettings{optimize: optimize?} = AdminRoom.get_media_settings()
    optimize?
  end

  defp default_scenario do
    %MediaSettings{functionality: scenario} = AdminRoom.get_media_settings()
    Map.get(@supervisor_map, scenario)
  end

  defp drive_blank?(path) do
    File.ls!(path)
    |> Enum.empty?()
  end

  defp optimize_fs(path) do
    device = Mount.device(path)

    device
    |> tap(fn device ->
      Process.sleep(1000)
      {output, code} = Mount.unmount("/dev/" <> device)

      Logger.debug([
        "[drive] [decider] Unmounting #{device}\n",
        "exit code: #{code} \n",
        output
      ])
    end)
    |> tap(fn device ->
      Process.sleep(1000)
      {output, code} = Mkfs.f2fs(device)

      Logger.info([
        "[drive] [decider] F2FS optimization for #{device}\n",
        "exit code: #{code} \n",
        output
      ])
    end)
    |> Mount.mount_at_path(path)
  end

  defp start(nil, _, _, _), do: :skip

  defp start(scenario, supervisor, device, path) do
    :ok =
      supervisor
      |> DynamicSupervisor.start_child({scenario, [device, path]})
      |> case do
        {:ok, _} ->
          :ok

        error ->
          Logger.error([
            "[drive] [decider] Error staring scenario #{scenario}\n",
            inspect(error, pretty: true)
          ])

          error
      end
  end
end
