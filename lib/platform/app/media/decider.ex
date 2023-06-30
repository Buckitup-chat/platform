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
  def init([device, opts]) do
    mount_path = Keyword.fetch!(opts, :mounted)
    next_opts = Keyword.fetch!(opts, :next)
    next_supervisor = Keyword.fetch!(next_opts, :under)

    "Platform.App.Media.Decider start" |> Logger.info()

    scenario_supervisor =
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

    "Platform.App.Media.Decider starting #{scenario_supervisor}" |> Logger.info()

    :ok =
      next_supervisor
      |> DynamicSupervisor.start_child({scenario_supervisor, [device]})
      |> case do
        {:ok, _} ->
          :ok

        error ->
          Logger.error([
            "[media] [decider] Error staring scenario #{scenario_supervisor}\n",
            inspect(error, pretty: true)
          ])

          error
      end

    {:ok, nil}
  end
end
