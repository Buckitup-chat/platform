defmodule Platform.App.Media.Decider do
  use GenServer

  require Logger

  alias Chat.Admin.MediaSettings
  alias Chat.AdminRoom
  alias Chat.Sync.UsbDriveDumpRoom
  alias Platform.App.Db.BackupDbSupervisor
  alias Platform.App.Sync.{CargoSyncSupervisor, OnlinersSyncSupervisor, UsbDriveDumpSupervisor}

  @supervisor_map %{
    backup: BackupDbSupervisor,
    cargo: CargoSyncSupervisor,
    onliners: OnlinersSyncSupervisor
  }

  def start_link(args) do
    GenServer.start_link(__MODULE__, args, [])
  end

  @impl GenServer
  def init([device, mount_path]) do
    "Platform.App.Media.Decider start" |> Logger.info()

    supervisor =
      cond do
        UsbDriveDumpRoom.get() ->
          UsbDriveDumpSupervisor

        File.exists?("#{mount_path}/cargo_db") ->
          CargoSyncSupervisor

        File.exists?("#{mount_path}/onliners_db") ->
          OnlinersSyncSupervisor

        File.exists?("#{mount_path}/backup_db") ->
          BackupDbSupervisor

        true ->
          %MediaSettings{} = media_settings = AdminRoom.get_media_settings()
          Map.get(@supervisor_map, media_settings.functionality)
      end

    "Platform.App.Media.Decider starting #{supervisor}" |> Logger.info()

    {:ok, _pid} =
      Platform.App.Media.FunctionalityDynamicSupervisor
      |> DynamicSupervisor.start_child({supervisor, [device]})

    {:ok, nil}
  end
end
