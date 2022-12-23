defmodule Platform.App.DbSupervisor do
  @moduledoc """
  Handles Main and Backup database supervision trees
  """
  use Supervisor

  def start_link(init_arg) do
    Supervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl true
  def init(_init_arg) do
    children = [
      {DynamicSupervisor, name: Platform.MainDbSupervisor, strategy: :one_for_one},
      {DynamicSupervisor, name: Platform.BackupDbSupervisor, strategy: :one_for_one}
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end
end
