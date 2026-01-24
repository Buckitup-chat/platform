defmodule Platform.App.Drive.UsbDriveDumpSupervisor do
  @moduledoc "Usb drive dump scenario"
  use Supervisor
  use Toolbox.OriginLog
  import Platform

  alias Platform.App.Sync.UsbDriveDump.Completer
  alias Platform.App.Sync.UsbDriveDump.Dumper
  alias Platform.App.Drive.UsbDriveDumpSupervisor.Tasks
  alias Platform.Storage.Backup.Starter

  def start_link(init_arg) do
    Supervisor.start_link(__MODULE__, init_arg,
      name: __MODULE__,
      max_restarts: 1,
      max_seconds: 15
    )
  end

  @impl Supervisor
  def init([_device, path | _]) do
    log("start", :info)

    full_path = [path, "DCIM"] |> Path.join()
    tasks = Tasks

    [
      use_task(tasks),
      {Starter, flag: :usb_drive_dump},
      {:stage, Dump, {Dumper, mounted: full_path, task_in: tasks} |> exit_takes(10_000)},
      Completer
    ]
    |> prepare_stages(Platform.App.Drive.UsbDriveDumpStages)
    |> Supervisor.init(strategy: :rest_for_one, max_restarts: 1, max_seconds: 5)
    |> tap(fn res ->
      log("init result #{inspect(res)}", :debug)
    end)
  end
end
