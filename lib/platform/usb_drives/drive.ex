defmodule Platform.UsbDrives.Drive do
  @moduledoc "Drive functions"

  def registry_name(stage, drive) do
    {:via, Registry, {Platform.Drives.Registry, {stage, drive}}}
  end

  def registry_lookup(stage, drive) do
    Registry.lookup(Platform.Drives.Registry, {stage, drive})
  end

  def terminate(drive) do
    Task.Supervisor.start_child(Platform.TaskSupervisor, fn ->
      mounted = registry_name(Mounted, drive)

      mounted
      |> DynamicSupervisor.which_children()
      |> Enum.each(fn {_, pid, _, _} ->
        DynamicSupervisor.terminate_child(mounted, pid)
      end)

      healed = registry_name(Healed, drive)

      healed
      |> DynamicSupervisor.which_children()
      |> Enum.each(fn {_, pid, _, _} ->
        DynamicSupervisor.terminate_child(healed, pid)
      end)
    end)
  end
end
