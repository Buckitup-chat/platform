defmodule Platform.App.Sync.UsbDriveDump.Logic do
  @moduledoc """
  Starts dumping USB drive files to the specified room.
  """

  use GenServer

  require Logger

  alias Chat.Sync.{UsbDriveDumpFile, UsbDriveDumpRoom, UsbDriveFileDumper}
  alias Platform.Leds

  def start_link(args) do
    GenServer.start_link(__MODULE__, args, [])
  end

  @impl GenServer
  def init([path, tasks_name]) do
    "Platform.App.Sync.UsbDriveDump.Logic dumping" |> Logger.info()

    Process.flag(:trap_exit, true)

    {:ok, dump(path, tasks_name)}
  end

  # handle the trapped exit call
  @impl GenServer
  def handle_info({:EXIT, _from, reason}, state) do
    Logger.info("exiting #{__MODULE__}")
    cleanup(reason, state)
    {:stop, reason, state}
  end

  @impl GenServer
  def terminate(reason, state) do
    Logger.info("terminating #{__MODULE__}")
    cleanup(reason, state)
    state
  end

  defp dump(path, tasks_name) do
    UsbDriveDumpRoom.dump()

    try do
      Task.Supervisor.async_nolink(tasks_name, fn ->
        Leds.blink_read()

        dump_room = UsbDriveDumpRoom.get()

        "#{path}/**/*.*"
        |> Path.wildcard()
        |> Enum.map(fn path ->
          filename =
            path
            |> Path.split()
            |> List.last()

          %File.Stat{size: size, mtime: time} = File.stat!(path)
          datetime = NaiveDateTime.from_erl!(time)

          %UsbDriveDumpFile{datetime: datetime, name: filename, path: path, size: size}
        end)
        |> Enum.sort_by(& &1.datetime, NaiveDateTime)
        |> Enum.each(&UsbDriveFileDumper.dump(&1, dump_room.pub_key, dump_room.identity))

        UsbDriveDumpRoom.mark_successful()

        "Platform.App.Sync.UsbDriveDump.Logic dumping finished" |> Logger.info()
        Leds.blink_done()
      end)
      |> Task.await(:infinity)
    rescue
      _ ->
        nil
    end

    UsbDriveDumpRoom.complete()
  end

  defp cleanup(_reason, _state) do
    UsbDriveDumpRoom.remove()
  end
end
