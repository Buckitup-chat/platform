defmodule Platform.App.Sync.UsbDriveDumpSupervisor do
  use Supervisor
  import Platform

  require Logger

  alias Platform.App.Sync.UsbDriveDump.Completer
  alias Platform.App.Sync.UsbDriveDump.Dumper
  alias Platform.App.Sync.UsbDriveDumpSupervisor.Tasks
  alias Platform.Storage.Backup.Starter

  @mount_path Application.compile_env(:platform, :mount_path_media)

  def start_link(init_arg) do
    Supervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl Supervisor
  def init([_device]) do
    "UsbDriveDumpSupervisor start" |> Logger.info()

    full_path = [@mount_path, "DCIM"] |> Path.join()
    tasks = Tasks
    files_dumped_stage = Platform.App.Sync.UsbDriveDump.FilesDumpedStage

    [
      use_task(tasks),
      {Starter, flag: :usb_drive_dump},
      use_next_stage(files_dumped_stage),
      {Dumper,
       mounted: full_path,
       task_in: tasks,
       next: [
         under: files_dumped_stage,
         run: [
           Completer
         ]
       ]}
    ]
    |> Supervisor.init(strategy: :rest_for_one)
    |> tap(fn res ->
      "UsbDriveDumpSupervisor init result #{inspect(res)}" |> Logger.debug()
    end)
  end
end
