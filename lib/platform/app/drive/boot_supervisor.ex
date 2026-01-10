defmodule Platform.App.Drive.BootSupervisor do
  @moduledoc "Starts drive booting (till be able to decide what to do next)"

  use Supervisor
  use OriginLog

  import Platform

  alias Platform.Storage.DriveIndicationStarter
  alias Platform.Storage.InternalDbAwaiter
  alias Platform.UsbDrives.Decider

  def start_link([device, name]) do
    Supervisor.start_link(__MODULE__, [device],
      name: name,
      max_restarts: 1,
      max_seconds: 15
    )
  end

  def init([device]) do
    device
    |> supervision_tree()
    |> Supervisor.init(strategy: :rest_for_one, max_restarts: 1, max_seconds: 5)
    |> tap(fn res ->
      log("init result #{inspect(res)}", :debug)
    end)
  end

  if :host == Application.compile_env(:platform, :target) do
    @healer Platform.Emulator.Drive.Healer
    @mounter Platform.Emulator.Drive.Mounter
    @pg_daemon Platform.Emulator.EmptyBypass
    @pg_db_creator Platform.Emulator.EmptyBypass
    @pg_initializer Platform.Emulator.EmptyBypass
    @pg_repo_starter Platform.Emulator.EmptyBypass
    @pg_migration_runner Platform.Emulator.EmptyBypass
  else
    @healer Platform.Storage.Healer
    @mounter Platform.Storage.Mounter
    @pg_daemon Platform.Storage.Pg.Daemon
    @pg_db_creator Platform.Storage.Pg.DbCreator
    @pg_initializer Platform.Storage.Pg.Initializer
    @pg_repo_starter Platform.Storage.Repo.Starter
    @pg_migration_runner Platform.Storage.Repo.MigrationRunner
  end

  @mount_path Application.compile_env(:platform, :mount_path_media)

  def supervision_tree(device) do
    task_supervisor = name(BootTask, device)
    next_supervisor = name(Scenario, device)

    mount_path = [@mount_path, device] |> Path.join()
    pg_dir = [mount_path, "pg"] |> Path.join()
    port = pg_port_for_device(device)
    repo_name = atom_name(Repo, device)

    Application.get_env(:chat, Chat.Repo)
    |> Keyword.put(:port, port)
    |> then(&Application.put_env(:platfrom, repo_name, &1))

    repo_module_content =
      quote do
        use Ecto.Repo,
          otp_app: :platform,
          adapter: Ecto.Adapters.Postgres
      end

    Module.create(repo_name, repo_module_content, Macro.Env.location(__ENV__))

    [
      use_task(task_supervisor),
      {DriveIndicationStarter, []} |> exit_takes(15_000),
      {:stage, name(Healed, device), {@healer, device: device, task_in: task_supervisor}},
      {:step, name(Mounted, device),
       {@mounter,
        device: device, at: mount_path, mount_options: mount_options(), task_in: task_supervisor}
       |> exit_takes(15_000)},
      {:step, name(InitPg, device),
       {@pg_initializer, pg_dir: pg_dir, pg_port: port, task_in: task_supervisor}
       |> exit_takes(30_000)},
      {:stage, name(PgServer, device),
       {@pg_daemon,
        pg_dir: pg_dir,
        pg_port: port,
        device: device,
        name: name(PgDaemon, device),
        task_in: task_supervisor}
       |> exit_takes(180_000)},
      {:step, name(DbCreated, device),
       {@pg_db_creator, db_name: "chat", pg_port: port, task_in: task_supervisor}
       |> exit_takes(15_000)},
      {:stage, name(RepoStarted, device),
       {@pg_repo_starter, name: repo_name, port: port, task_in: task_supervisor}
       |> exit_takes(30_000)},
      {:step, name(MigrationsRun, device),
       {@pg_migration_runner, repo_name: repo_name, task_in: task_supervisor}
       |> exit_takes(60_000)},
      {:step, name(InternalDbReady, device), {InternalDbAwaiter, task_in: task_supervisor}},
      use_next_stage(next_supervisor) |> exit_takes(90_000),
      {Decider,
       [
         device,
         [
           mounted: mount_path,
           pg_dir: pg_dir,
           pg_port: port,
           repo: repo_name,
           next: [under: next_supervisor]
         ]
       ]}
    ]
    |> prepare_stages(Platform.App.Drive.Boot)
  end

  defp atom_name(suffix, device) do
    "sd" <> <<index::bitstring-size(8)>> <> _ = device

    Module.concat([Platform.Dev, :"Sd#{index}", suffix])
  end

  defp name(stage, device) do
    Platform.UsbDrives.Drive.registry_name(stage, device)
  end

  defp pg_port_for_device(device) do
    "sd" <> <<index::8>> <> _ = device

    5432 + 1 + index - ?a
  end

  defp mount_options do
    try do
      uid = Platform.Tools.Postgres.get_postgres_uid()
      gid = Platform.Tools.Postgres.get_postgres_gid()
      [uid: uid, gid: gid]
    rescue
      _ -> []
    end
  end
end
