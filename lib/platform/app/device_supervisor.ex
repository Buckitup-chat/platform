defmodule Platform.App.DeviceSupervisor do
  @moduledoc """
  Handles Main and Backup database supervision trees
  """
  use Supervisor

  import Platform

  require Logger

  def start_link(init_arg) do
    Supervisor.start_link(__MODULE__, init_arg,
      name: __MODULE__,
      max_restarts: 30,
      max_seconds: 15
    )
  end

  @impl true
  def init(_init_arg) do
    "Device Supervisor start" |> Logger.debug()

    children =
      [
        {DynamicSupervisor, name: Platform.Drives, strategy: :one_for_one}
        |> exit_takes(150_000),
        {Registry, name: Platform.Drives.Registry, keys: :unique},
        Platform.UsbDrives.Detector.Watcher |> unless_on_host()
      ]
      |> Enum.reject(&is_nil/1)

    Supervisor.init(children, strategy: :one_for_one)
  end

  defp unless_on_host(x) do
    if Platform.Application.target() != :host do
      # coveralls-ignore-next-line
      x
    end
  end
end
