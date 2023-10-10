defmodule Platform.UsbDrives.Drive do
  @moduledoc "Drive functions"

  def registry_name(stage, drive) do
    {:via, Registry, {Platform.Drives.Registry, {stage, drive}}}
  end

  def registry_lookup(stage, drive) do
    Registry.lookup(Platform.Drives.Registry, {stage, drive})
  end

  def terminate(drive) do
    stage = registry_name(Healing, drive)

    stage
    |> DynamicSupervisor.which_children()
    |> Enum.each(fn {_, pid, _, _} ->
      DynamicSupervisor.terminate_child(stage, pid)
    end)
  end
end
