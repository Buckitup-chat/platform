defmodule Platform.Storage.Stopper do
  @moduledoc """
  Awaits few seconds and finalizes copying
  """

  require Logger

  alias Platform.Storage.DriveIndication
  alias Platform.Leds
  alias Platform.UsbDrives.Drive

  @default_wait if(Application.compile_env(:platform, :target) == :host, do: 100, else: 5000)

  def start_link(opts \\ []) do
    Logger.info("starting #{__MODULE__}")

    wait = Keyword.get(opts, :wait, @default_wait)

    Task.Supervisor.async_nolink(Platform.TaskSupervisor, fn ->
      Leds.blink_dump()
      DriveIndication.drive_complete()
      Logger.info("backup finished. Stopping supervisor")

      Process.sleep(wait)
      Drive.terminate(opts[:device])

      Leds.blink_done()
    end)

    {:ok, nil}
  end
end
