defmodule Platform.App.Drive.BackupDbSupervisor do
  @moduledoc "Backup DB device mount — starts CubDB, chunk pipeline, and the backup link plan (`Platform.Storage.BackupPlan`)."
  use Supervisor
  use Toolbox.OriginLog

  import Platform

  alias Chat.Admin.BackupSettings
  alias Chat.AdminRoom
  alias Chat.Data.File.ChunkPipelineSupervisor
  alias Chat.Storage.Unit
  alias Platform.Storage.BackupPlan
  alias Platform.Storage.Bouncer

  def start_link(init_arg) do
    Supervisor.start_link(__MODULE__, init_arg,
      name: __MODULE__,
      max_restarts: 1,
      max_seconds: 15
    )
  end

  @impl true
  def init([device, path, pg_opts]) do
    log("start", :info)

    type = "backup_db"
    full_path = [path, type, Chat.Db.version_path()] |> Path.join()
    db = Chat.Db.BackupDb
    continuous? = match?(%BackupSettings{type: :continuous}, AdminRoom.get_backup_settings())

    # Registers the backup unit and pulls the blobs the plan's links queue for it
    chunk_pipeline =
      case Map.get(pg_opts, :repo) do
        nil -> []
        _ -> [{ChunkPipelineSupervisor, unit: Unit.usb(device, :backup)}]
      end

    ([
       {Task, fn -> File.mkdir_p!(full_path) end},
       {Chat.Db.MediaDbSupervisor, [db, full_path]} |> exit_takes(20_000),
       {Bouncer, db: db, type: type}
     ] ++
       chunk_pipeline ++
       [
         # Follows the Default: restarts or re-homes on {:default_switched, _}
         {BackupPlan, device: device, continuous?: continuous?} |> exit_takes(35_000)
       ])
    |> Supervisor.init(strategy: :rest_for_one, max_restarts: 1, max_seconds: 5)
    |> tap(fn res ->
      log("init result #{inspect(res)}", :debug)
    end)
  end
end
