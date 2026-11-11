defmodule Platform.Emulator.Drive.FsOptimizer do
  @moduledoc "Host stand-in for `Platform.Storage.FsOptimizer`: empties the drive dir"

  use Toolbox.OriginLog

  def optimize(path) do
    log("F2FS optimization emulated for #{path}", :info)

    path
    |> File.ls!()
    |> Enum.each(&(path |> Path.join(&1) |> File.rm_rf!()))
  end
end
