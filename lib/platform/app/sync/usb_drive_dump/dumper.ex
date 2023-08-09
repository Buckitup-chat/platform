defmodule Platform.App.Sync.UsbDriveDump.Dumper do
  @moduledoc """
  Starts dumping USB drive files to the specified room.
  """

  use GracefulGenServer

  require Logger

  alias Chat.Sync.{UsbDriveDumpFile, UsbDriveDumpRoom, UsbDriveFileDumper}
  alias Platform.Leds

  @impl true
  def on_init(opts) do
    next_opts = Keyword.fetch!(opts, :next)
    Process.send_after(self(), :start, 10)

    %{
      path: Keyword.fetch!(opts, :mounted),
      task_supervisor: Keyword.fetch!(opts, :task_in),
      next_specs: Keyword.fetch!(next_opts, :run),
      next_supervisor: Keyword.fetch!(next_opts, :under),
      task_ref: nil
    }
  end

  @impl true
  def on_msg(
        :start,
        %{
          path: path,
          task_supervisor: tasks_name
        } = state
      ) do
    "Platform.App.Sync.UsbDriveDump.Logic dumping started" |> Logger.info()

    UsbDriveDumpRoom.dump()

    %{ref: ref} =
      Task.Supervisor.async_nolink(tasks_name, fn ->
        Leds.blink_read()

        %UsbDriveDumpRoom{} = dump_room = UsbDriveDumpRoom.get()

        {files, total_size} = gather_files(path)

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

    {:noreply, %{state | task_ref: ref}}
  end

  def on_msg({ref, _}, %{task_ref: ref} = state) do
    Process.demonitor(ref, [:flush])
    send(self(), :dumped)
    {:noreply, state}
  end

  def on_msg(
        :dumped,
        %{
          next_specs: next_specs,
          next_supervisor: next_supervisor
        } = state
      ) do
    Platform.start_next_stage(next_supervisor, next_specs)
    {:noreply, state}
  end

  @impl true
  def on_exit(_reason, _state) do
    Leds.blink_done()
    UsbDriveDumpRoom.remove()
  end

  defp gather_files(path) do
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
  end
end
