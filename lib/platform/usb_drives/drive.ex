defmodule Platform.UsbDrives.Drive do
  @moduledoc "Drive functions"

  def registry_name(stage, drive) do
    {:via, Registry, {Platform.App.Drive.BootRegistry, {stage, drive}}}
  end

  def registry_lookup(stage, drive) do
    Registry.lookup(Platform.App.Drive.BootRegistry, {stage, drive})
  end
end
