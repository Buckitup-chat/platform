defmodule Platform.App.Drive.BootSupervisor do
  @moduledoc "Starts drive booting (till be able to decide what to do next)"

  use Supervisor

  import Platform

  require Logger

  alias Platform.Storage.DriveIndicationStarter
  alias Platform.UsbDrives.Decider

  @healer (Application.compile_env(:platform, :target) == :host &&
             Platform.Emulator.Drive.Healer) || Platform.Storage.Healer
  @mounter (Application.compile_env(:platform, :target) == :host &&
              Platform.Emulator.Drive.Mounter) || Platform.Storage.Mounter

  @mount_path Application.compile_env(:platform, :mount_path_media)

  def start_link([device, name]) do
    Supervisor.start_link(__MODULE__, [device],
      name: name,
      max_restarts: 1,
      max_seconds: 15
    )
  end

  def init([device]) do
    task_supervisor = name(BootTask, device)
    next_supervisor = name(Scenario, device)

    mount_path = [@mount_path, device] |> Path.join()

    [
      use_task(task_supervisor),
      {DriveIndicationStarter, []} |> exit_takes(15_000),
      {:stage, name(Healed, device), {@healer, device: device, task_in: task_supervisor}},
      {:step, name(Mounted, device),
       {@mounter, device: device, at: mount_path, task_in: task_supervisor} |> exit_takes(15_000)},
      use_next_stage(next_supervisor) |> exit_takes(90_000),
      {Decider, [device, [mounted: mount_path, next: [under: next_supervisor]]]}
    ]
    |> prepare_stages(Platform.App.Drive.Boot)
    |> Supervisor.init(strategy: :rest_for_one, max_restarts: 1, max_seconds: 5)
    |> tap(fn res ->
      "Platform.App.Drives.BootSupervisor init result #{inspect(res)}" |> Logger.debug()
    end)
  end

  defp name(stage, device) do
    Platform.UsbDrives.Drive.registry_name(stage, device)
  end
end
