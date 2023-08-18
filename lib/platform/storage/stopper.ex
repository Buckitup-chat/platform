defmodule Platform.Storage.Stopper do
  @moduledoc """
  Awaits few seconds and finalizes copying
  """

  require Logger

  alias Platform.Storage.DriveIndication
  alias Platform.Leds

  @default_wait if(Application.compile_env(:platform, :target) == :host, do: 100, else: 5000)

  def start_link(opts \\ []) do
    Logger.info("starting #{__MODULE__}")

    wait = Keyword.get(opts, :wait, @default_wait)

    Task.Supervisor.async_nolink(Platform.TaskSupervisor, fn ->
      Leds.blink_dump()
      DriveIndication.drive_complete()
      Logger.info("backup finished. Stopping supervisor")

      Process.sleep(wait)

      case Process.whereis(Platform.App.Media.Supervisor) do
        nil ->
          nil

        pid ->
          DynamicSupervisor.terminate_child(Platform.App.Media.DynamicSupervisor, pid)
      end

      Leds.blink_done()
    end)

    {:ok, nil}
  end
end
