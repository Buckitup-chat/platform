defmodule Platform.App.DeviceSupervisor do
  @moduledoc """
  Handles Main and Backup database supervision trees
  """
  use Supervisor

  require Logger

  def start_link(init_arg) do
    Supervisor.start_link(__MODULE__, init_arg, name: __MODULE__, max_restarts: 1, max_seconds: 15)
  end

  @impl true
  def init(_init_arg) do
    "Device Supervisor start" |> Logger.debug()

    children = [
      {DynamicSupervisor, name: Platform.MainDbSupervisor, strategy: :one_for_one},
      {DynamicSupervisor, name: Platform.App.Media.DynamicSupervisor, strategy: :one_for_one},
      Platform.UsbWatcher
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
