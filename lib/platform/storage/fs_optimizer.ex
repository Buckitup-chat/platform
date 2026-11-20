defmodule Platform.Storage.FsOptimizer do
  @moduledoc "Reformats a blank drive as F2FS and mounts it back at the same path"

  use Toolbox.OriginLog

  alias Platform.Tools.Mkfs
  alias Platform.Tools.Mount

  def optimize(path) do
    path
    |> Mount.device()
    |> tap(fn device ->
      Process.sleep(1000)
      {output, code} = Mount.unmount("/dev/" <> device)

      log(
        [
          "Unmounting #{device}\n",
          "exit code: #{code} \n",
          output
        ],
        :debug
      )
    end)
    |> tap(fn device ->
      Process.sleep(1000)
      {output, code} = Mkfs.f2fs(device)

      log(
        [
          "F2FS optimization for #{device}\n",
          "exit code: #{code} \n",
          output
        ],
        :info
      )
    end)
    |> Mount.mount_at_path(path)
  end
end
