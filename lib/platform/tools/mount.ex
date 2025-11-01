defmodule Platform.Tools.Mount do
  @moduledoc "mount wrapper"

  require Logger
  alias Platform.Tools.Proto.Device

  def mount_at_path(device, path, mount_options \\ []) do
    log_mounting(device, path)
    mount([device |> Device.path(), path], mount_options)
  end

  @doc """
  Remount a directory with custom mount options using bind mount.
  Uses bind mount to apply different mount options to a subdirectory.
  
  ## Options
  - `:noatime` - Don't update access times (default: true)
  - `:nodiratime` - Don't update directory access times (default: true)
  - `:async` - Use async instead of sync (default: false, keep sync for safety)
  
  ## Examples
  
      # Optimize for database performance
      Mount.remount_with_options("/mnt/usb/pg", noatime: true, nodiratime: true)
      
      # Use async for temporary data
      Mount.remount_with_options("/tmp/cache", async: true)
  """
  def remount_with_options(dir, opts \\ []) do
    # Build mount options based on provided options
    opts_str =
      [
        if(Keyword.get(opts, :noatime, true), do: "noatime"),
        if(Keyword.get(opts, :nodiratime, true), do: "nodiratime"),
        if(Keyword.get(opts, :async, false), do: "async", else: "sync")
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join(",")
    
    Logger.info("[platform] Remounting #{dir} with options: #{opts_str}")
    
    # Use bind mount to apply different options to subdirectory
    # This is a standard Linux pattern - creates a second mount point for the same location
    # with different mount options, without creating circular references
    {_, status1} = System.cmd("mount", ["--bind", dir, dir])
    {output, status2} = System.cmd("mount", ["-o", "remount,#{opts_str}", dir])
    
    if status1 != 0 or status2 != 0 do
      Logger.warning("[platform] Failed to remount #{dir}: #{output}")
      {:error, output}
    else
      Logger.info("[platform] Successfully remounted #{dir}")
      :ok
    end
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
        do: ["-o", "noatime,nodiratime,sync,uid=#{uid},gid=#{gid},umask=0027"],
        else: ["-o", "noatime,nodiratime,sync"]

    System.cmd("mount", Enum.concat(mount_opts, params))
  end

  defp log_mounting(device, path) do
    Logger.info("[platform] Mounting #{device |> Device.path()} at #{path}")
  end
end
