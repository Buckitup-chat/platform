defmodule Platform.Storage.Device do
  @moduledoc """
  Device level operations
  """
  require Logger

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
    Logger.info("[platform] #{device} health checked")

    device
  end

  def mount_on(device, path) do
    File.mkdir_p!(path)
    Mount.unmount(path)
    {_, 0} = Mount.mount_at_path(device, path)

    path
  end

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
