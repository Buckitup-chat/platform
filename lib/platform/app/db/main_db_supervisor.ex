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

  @mount_path Application.compile_env(:platform, :mount_path_storage)

  def start_link(init_arg) do
    Supervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl true
  def init([device]) do
    "Main Db Supervisor start" |> Logger.debug()

    full_path = [@mount_path, "main_db", Chat.Db.version_path()] |> Path.join()
    tasks = Platform.App.Db.MainDbSupervisor.Tasks

    children = [
      {Task.Supervisor, name: tasks},
      {Task, fn -> File.mkdir_p!(full_path) end},
      {Chat.Db.MainDbSupervisor, full_path},
      Starter,
      {Copier, tasks},
      MainReplicator,
      Switcher
    ]

    children =
      case Application.get_env(:platform, :env) do
        :test ->
          children

        _ ->
          List.insert_at(children, 1, {Mounter, [device, @mount_path, tasks]})
      end

    Supervisor.init(children, strategy: :rest_for_one)
  end
end
