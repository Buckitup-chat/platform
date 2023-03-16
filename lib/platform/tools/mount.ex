defmodule Platform.Tools.Mount do
  @moduledoc "mount wrapper"

  def mount_at_path(device, path) do
    mount(["/dev/" <> device, path])
  end

  def unmount(path) do
    System.cmd("umount", [path])
  end

  def resize_tmp(size) do
    mount(["/tmp", "-o", "remount,size=" <> size])
  end

  def device(mountpoint, print_source \\ &print/0) do
    print_source.()
    |> parse_print()
    |> Enum.find(&(elem(&1, 1) == mountpoint))
    |> elem(0)
    |> elem(1)
  end

  defp parse_print(output) do
    output
    |> String.split("\n", trim: true)
    |> Enum.map(fn line ->
      [dev_data, rest] = line |> split_by(" on ")
      [mountpoint, fs] = rest |> split_by(" type ")
      [type, options] = fs |> split_by(" ")

      case dev_data do
        "/dev/" <> device -> {{:device, device}, mountpoint, type, options}
        device -> {{:module, device}, mountpoint, type, options}
      end
    end)
  end

  defp split_by(str, delimiter), do: String.split(str, delimiter, parts: 2)

  defp print do
    mount()
    |> elem(0)
  end

  defp mount(params \\ []) do
    System.cmd("mount", Enum.concat(["-o", "sync"], params))
  end
end
