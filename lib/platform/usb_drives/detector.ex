defmodule Platform.UsbDrives.Detector do
  @moduledoc "Drive detector side effects"

  require Logger

  alias Platform.App.Drive.BootSupervisor
  alias Platform.Storage.DriveIndication
  alias Platform.UsbDrives.Drive

  def start_initial_indication do
    Task.Supervisor.async_nolink(Platform.TaskSupervisor, fn ->
      DriveIndication.drive_init()
      Process.sleep(250)
      DriveIndication.drive_reset()
    end)
  end

  def insert(device) do
    eject(device)

    Platform.Drives
    |> DynamicSupervisor.start_child(
      {BootSupervisor, [device, Drive.registry_name(BootSupervisor, device)]}
    )
  end

  def eject(device) do
    Drive.registry_lookup(BootSupervisor, device)
    |> case do
      [{pid, _value}] -> Platform.Drives |> DynamicSupervisor.terminate_child(pid)
      _ -> :none
    end
  end

  def log_added(devices) do
    Logger.debug("[drive detector] added: " <> Enum.join(devices, ", "))
  end

  def log_removed(devices) do
    Logger.debug("[drive detector] removed: " <> Enum.join(devices, ", "))
  end
end
