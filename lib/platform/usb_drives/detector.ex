defmodule Platform.UsbDrives.Detector do
  @moduledoc "Drive detector side effects"

  require Logger

  alias Platform.Storage.DriveIndication

  def start_initial_indication do
    Task.Supervisor.async_nolink(Platform.TaskSupervisor, fn ->
      DriveIndication.drive_init()
      Process.sleep(250)
      DriveIndication.drive_reset()
    end)
  end

  def insert(device) do
    #    Logic.on_new([device])
  end

  def eject(device) do
    # Logic.on_remove([device], still_connected |> MapSet.to_list())
  end

  def log_added(devices) do
    Logger.debug("[drive detector] added: " <> Enum.join(devices, ", "))
  end

  def log_removed(devices) do
    Logger.debug("[drive detector] removed: " <> Enum.join(devices, ", "))
  end
end
