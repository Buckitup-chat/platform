defmodule Platform.Tools.Mount do
  @moduledoc "mount/unmount wrapper"

  use OriginLog
  alias Platform.Tools.Proto.Device

  def mount_at_path(device, path, mount_options \\ []) do
    log_mounting(device, path)
    mount([device |> Device.path(), path], mount_options)
  end

  def unmount(device) do
    System.cmd("umount", ["-f", device |> Device.path()])
  end

  def resize_tmp(size) do
    mount(["/tmp", "-o", "remount,size=" <> size], [])
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
    mount([], [])
    |> elem(0)
  end

  defp mount(params, mount_options) do
    uid = mount_options |> Keyword.get(:uid)
    gid = mount_options |> Keyword.get(:gid)

    mount_opts =
      if uid && gid,
        do: ["-o", "noatime,nodiratime,sync,uid=#{uid},gid=#{gid},umask=0077,fmask=0177"],
        else: ["-o", "noatime,nodiratime,sync"]

    System.cmd("mount", Enum.concat(mount_opts, params))
  end

  defp log_mounting(device, path) do
    log("Mounting #{device |> Device.path()} at #{path}", :info)
  end
end
