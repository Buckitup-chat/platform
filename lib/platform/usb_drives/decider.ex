defmodule Platform.UsbDrives.Decider do
  @moduledoc "Decides scenario"

  use GenServer

  require Logger

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
      create_first_main?() -> MainDbSupervisor
      true -> default_scenario()
    end
  end

  defp on_internal_db? do
    Chat.Db.Common.get_chat_db_env(:mode) == :internal
  end

  defp create_first_main? do
    %MediaSettings{main: create_main?} = AdminRoom.get_media_settings()

    create_main? and on_internal_db?()
  end

  defp default_scenario do
    %MediaSettings{functionality: scenario} = AdminRoom.get_media_settings()
    Map.get(@supervisor_map, scenario)
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
