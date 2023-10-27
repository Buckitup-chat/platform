defmodule Platform.UsbDrives.Drive do
  @moduledoc "Drive functions"

  def registry_name(stage, drive) do
    {:via, Registry, {Platform.Drives.Registry, {stage, drive}}}
  end

  def registry_lookup(stage, drive) do
    Registry.lookup(Platform.Drives.Registry, {stage, drive})
  end

  def terminate(nil), do: :skip

  def terminate(drive) do
    Task.Supervisor.start_child(Platform.TaskSupervisor, fn ->
      registry_name(Mounted, drive)
      |> terminate_children()

      registry_name(Healed, drive)
      |> terminate_children()
    end)
  end

  defp terminate_children(name) do
    name
    |> DynamicSupervisor.which_children()
    |> Enum.each(fn {_, pid, _, _} ->
      try do
        DynamicSupervisor.terminate_child(name, pid)
      rescue
        _ -> :skip
      end
    end)
  rescue
    _ -> :skip
  end
end
