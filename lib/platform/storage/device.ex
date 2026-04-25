defmodule Platform.Storage.Device do
  @moduledoc """
  Device level operations
  """
  use Toolbox.OriginLog

  alias Chat.Db.Maintenance
  alias Platform.Leds
  alias Platform.Tools.Fsck
  alias Platform.Tools.Lsblk
  alias Platform.Tools.Mount

  def heal(device) do
    Leds.blink_read()

    case Lsblk.fs_type(device) do
      "vfat" -> Fsck.vfat(device)
      "f2fs" -> Fsck.f2fs(device)
      "exfat" -> Fsck.exfat(device)
      _ -> false
    end

    Leds.blink_done()
    log("#{device} health checked", :info)

    device
  end

  def mount_on(device, path, mount_options \\ []) do
    fs = Lsblk.fs_type(device)
    :ok = assert_writable_fs(fs, device)
    mount_options = filter_mount_options(fs, mount_options)

    File.mkdir_p!(path)
    Mount.unmount(path)
    {_, 0} = Mount.mount_at_path(device, path, mount_options)

    path
  end

  defp assert_writable_fs(fs, device) when fs in ["squashfs", "iso9660"] do
    log("#{device} has read-only filesystem #{fs}, skipping", :error)
    raise "read-only filesystem #{fs} on #{device}"
  end

  defp assert_writable_fs(_fs, _device), do: :ok

  defp filter_mount_options(fs, mount_options) when fs in ["vfat", "exfat"], do: mount_options
  defp filter_mount_options(_fs, mount_options), do: Keyword.drop(mount_options, [:uid, :gid])

  def unmount(device) do
    case device do
      "/dev/" <> _ -> device
      _ -> "/dev/#{device}"
    end
    |> Maintenance.device_to_path()
    |> then(fn
      nil -> :nothing_to_unmount
      path -> Mount.unmount(path)
    end)
  end
end
