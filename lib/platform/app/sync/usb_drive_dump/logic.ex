defmodule Platform.App.Sync.UsbDriveDump.Logic do
  @moduledoc """
  Starts dumping USB drive files to the specified room.
  """

  use GracefulGenServer

  require Logger

  alias Chat.Sync.{UsbDriveDumpFile, UsbDriveDumpRoom, UsbDriveFileDumper}
  alias Platform.Leds

  @impl true
  def on_init([path, tasks_name]) do
    UsbDriveDumpRoom.dump()

    try do
      Task.Supervisor.async_nolink(tasks_name, fn ->
        Leds.blink_read()

        %UsbDriveDumpRoom{} = dump_room = UsbDriveDumpRoom.get()

        {files, total_size} =
          "#{path}/**/*.*"
          |> Path.wildcard()
          |> Enum.map_reduce(0, fn path, total_size ->
            filename =
              path
              |> Path.split()
              |> List.last()

            %File.Stat{size: size, mtime: time} = File.stat!(path)
            datetime = NaiveDateTime.from_erl!(time)
            file = %UsbDriveDumpFile{datetime: datetime, name: filename, path: path, size: size}

            {file, total_size + size}
          end)

        UsbDriveDumpRoom.set_total(length(files), total_size)

        files
        |> Enum.sort_by(& &1.datetime, NaiveDateTime)
        |> Enum.with_index(1)
        |> Enum.each(fn {file, file_number} ->
          UsbDriveFileDumper.dump(
            file,
            file_number,
            dump_room.pub_key,
            dump_room.identity,
            dump_room.monotonic_offset
          )
        end)

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

  @impl true
  def on_exit(_reason, _state) do
    UsbDriveDumpRoom.remove()
  end
end
