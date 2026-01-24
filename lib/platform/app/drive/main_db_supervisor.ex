defmodule Platform.App.Drive.MainDbSupervisor do
  @moduledoc """
  Main DB device mount
  """
  use Supervisor
  use Toolbox.OriginLog

  import Platform

  alias Platform.Storage.{
    Bouncer,
    MainReplicator
  }

  alias Platform.Storage.InternalToMain.{
    Copier,
    Starter,
    Switcher
  }

  alias Platform.Storage.PhoenixSyncInit

  def start_link(init_arg) do
    Supervisor.start_link(__MODULE__, init_arg,
      name: __MODULE__,
      max_restarts: 1,
      max_seconds: 15
    )
  end

  @impl true
  def init([_device, path, pg_opts]) do
    log("start", :debug)

    full_path = [path, "main_db", Chat.Db.version_path()] |> Path.join()
    task_supervisor = Platform.App.Drive.MainDbSupervisor.Tasks

    [
      use_task(task_supervisor),
      dir_creator(full_path),
      {Chat.Db.MainDbSupervisor, full_path} |> exit_takes(20_000),
      {Bouncer, db: Chat.Db.MainDb, type: "main_db"},
      Starter |> exit_takes(1000),
      {:stage, Copying,
       {Copier, task_in: task_supervisor, pg_opts: pg_opts} |> exit_takes(25_000)},
      MainReplicator,
      {Switcher, pg_opts: pg_opts} |> exit_takes(1000),
      PhoenixSyncInit |> exit_takes(5000)
    ]
    |> prepare_stages(Platform.App.MainStages)
    |> tap(fn specs ->
      specs
      |> calc_exit_time()
      |> then(&log("exit time #{inspect(&1)}", :debug))
    end)
    |> Supervisor.init(strategy: :rest_for_one, max_restarts: 1, max_seconds: 5)
  end

  defp dir_creator(path), do: {Task, fn -> File.mkdir_p!(path) end}
end
