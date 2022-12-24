defmodule Platform.App.Db.MainDbSupervisor do
  @moduledoc """
  Main DB device mount
  """
  use Supervisor
  require Logger

  alias Platform.Storage.InternalToMain.Copier
  alias Platform.Storage.InternalToMain.Starter
  alias Platform.Storage.InternalToMain.Switcher
  alias Platform.Storage.MainReplicator
  alias Platform.Storage.Mounter

  def start_link(init_arg) do
    Supervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl true
  def init([device]) do
    "Main Db Supervisor start" |> Logger.debug()

    mount_path = "/root/storage"
    full_path = [mount_path, "main_db", Chat.Db.version_path()] |> Path.join()
    tasks = Platform.App.Db.MainDbSupervisor.Tasks

    children = [
      {Task.Supervisor, name: tasks},
      {Mounter, [device, mount_path, tasks]},
      {Task, fn -> File.mkdir_p!(full_path) end},
      {Chat.Db.MainDbSupervisor, full_path},
      Starter,
      {Copier, tasks},
      MainReplicator,
      Switcher
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end
end
