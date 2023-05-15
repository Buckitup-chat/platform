defmodule Platform.App.Sync.UsbDriveDumpSupervisor do
  use Supervisor

  require Logger

  alias Platform.App.Sync.UsbDriveDump.Logic
  alias Platform.App.Sync.UsbDriveDumpSupervisor.Tasks
  alias Platform.Storage.Backup.Starter
  alias Platform.Storage.MountedHealer

  @mount_path Application.compile_env(:platform, :mount_path_media)

  def start_link(init_arg) do
    Supervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl Supervisor
  def init([device]) do
    "UsbDriveDumpSupervisor start" |> Logger.info()

    full_path = [@mount_path, "DCIM"] |> Path.join()
    tasks = Tasks

    [
      {Task.Supervisor, name: tasks},
      {MountedHealer, [device, full_path, tasks]},
      {Starter, flag: :usb_drive_dump},
      {Logic, [full_path, tasks]}
    ]
    |> Supervisor.init(strategy: :rest_for_one)
    |> tap(fn res ->
      "UsbDriveDumpSupervisor init result #{inspect(res)}" |> Logger.debug()
    end)
  end
end
