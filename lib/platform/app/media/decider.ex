defmodule Platform.App.Media.Decider do
  use GenServer

  require Logger

  alias Chat.Admin.MediaSettings
  alias Chat.AdminRoom
  alias Platform.App.Db.BackupDbSupervisor
  alias Platform.App.Sync.OnlinersSyncSupervisor

  @supervisor_map %{backup: BackupDbSupervisor, onliners: OnlinersSyncSupervisor}

  def start_link(args) do
    GenServer.start_link(__MODULE__, args, [])
  end

  @impl GenServer
  def init([device, mount_path]) do
    "Platform.App.Media.Decider start" |> Logger.info()

    {:ok, %{device: device, mount_path: mount_path}, {:continue, :choose_functionality}}
  end

  @impl GenServer
  def handle_continue(:choose_functionality, %{device: device, mount_path: mount_path} = state) do
    supervisor =
      cond do
        File.exists?("#{mount_path}/onliners_db") ->
          OnlinersSyncSupervisor

        File.exists?("#{mount_path}/bdb") ->
          BackupDbSupervisor

        true ->
          new_drive_supervisor()
      end

    "Platform.App.Media.Decider starting #{supervisor}" |> Logger.info()

    Platform.App.Media.FunctionalityDynamicSupervisor
    |> DynamicSupervisor.start_child({supervisor, [device]})

    {:noreply, state}
  end

  def new_drive_supervisor() do
    %MediaSettings{} = media_settings = AdminRoom.get_media_settings()
    Map.get(@supervisor_map, media_settings.functionality)
  end
end
