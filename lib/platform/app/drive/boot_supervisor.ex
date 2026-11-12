defmodule Platform.App.Drive.BootSupervisor do
  @moduledoc """
  Boots a drive: Healer → Mount → internal DB wait → `Resolver`.

  The resolved role builds the rest: PG stages only for roles with `:pg`, then
  `Decider` starts the scenario.
  """

  use Supervisor
  use Toolbox.OriginLog

  import Platform

  alias Chat.Storage.Role
  alias Platform.Storage.DriveIndicationStarter
  alias Platform.Storage.InternalDbAwaiter
  alias Platform.Tools.Postgres
  alias Platform.UsbDrives.Decider
  alias Platform.UsbDrives.Drive
  alias Platform.UsbDrives.Resolver

  def start_link([device, name]) do
    Supervisor.start_link(__MODULE__, [device],
      name: name,
      max_restarts: 3,
      max_seconds: 240
    )
  end

  def init([device]) do
    device
    |> supervision_tree()
    |> Supervisor.init(strategy: :rest_for_one, max_restarts: 3, max_seconds: 240)
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
    @pg_repo_starter Platform.Emulator.Drive.RepoStarter
    @pg_migration_runner Platform.Emulator.Drive.MigrationRunner
    @fs_optimizer Platform.Emulator.Drive.FsOptimizer

    # No per-drive PG server on host: each drive gets its own database on the local one
    defp pg_port_for_device(_device), do: Application.get_env(:chat, Chat.Repo)[:port]

    defp drive_repo_config(device, _port) do
      config = Application.get_env(:chat, Chat.Repo)
      Keyword.put(config, :database, "#{config[:database]}_#{device}")
    end
  else
    @healer Platform.Storage.Healer
    @mounter Platform.Storage.Mounter
    @pg_daemon Platform.Storage.Pg.Daemon
    @pg_db_creator Platform.Storage.Pg.DbCreator
    @pg_initializer Platform.Storage.Pg.Initializer
    @pg_repo_starter Platform.Storage.Repo.Starter
    @pg_migration_runner Platform.Storage.Repo.MigrationRunner
    @fs_optimizer Platform.Storage.FsOptimizer

    defp pg_port_for_device(device) do
      "sd" <> <<index::8>> <> _ = device

      5432 + 1 + index - ?a
    end

    defp drive_repo_config(_device, port) do
      Application.get_env(:chat, Chat.Repo) |> Keyword.put(:port, port)
    end
  end

  @mount_path Application.compile_env(:platform, :mount_path_media)

  def supervision_tree(device) do
    task_supervisor = name(BootTask, device)
    resolved_supervisor = name(RoleResolved, device)

    define_repo(device)

    [
      use_task(task_supervisor),
      {DriveIndicationStarter, []} |> exit_takes(15_000),
      {:stage, name(Healed, device), {@healer, device: device, task_in: task_supervisor}},
      {:step, name(Mounted, device),
       {@mounter,
        device: device,
        at: mount_path(device),
        mount_options: mount_options(),
        task_in: task_supervisor}
       |> exit_takes(15_000)},
      {:step, name(InternalDbReady, device), {InternalDbAwaiter, task_in: task_supervisor}},
      {Resolver,
       device: device,
       at: mount_path(device),
       optimizer: @fs_optimizer,
       under: resolved_supervisor,
       tree: &resolved_tree(device, &1)},
      use_next_stage(resolved_supervisor)
      |> exit_takes(device |> resolved_tree({:role, :main}) |> calc_exit_time())
    ]
    |> prepare_stages(Platform.App.Drive.Boot)
  end

  # Engines per role capabilities, then the scenario
  defp resolved_tree(device, resolution) do
    pg? =
      case resolution do
        {:role, role} -> :pg in Role.capabilities(role)
        _ -> false
      end

    next_supervisor = name(Scenario, device)

    pg_opts =
      if pg?,
        do: %{port: pg_port_for_device(device), dir: pg_dir(device), repo: repo_name(device)}

    [
      if(pg?, do: pg_stages(device), else: []),
      use_next_stage(next_supervisor) |> exit_takes(90_000),
      {Decider,
       [
         device,
         [
           mounted: mount_path(device),
           scenario: Decider.scenario(resolution),
           pg: pg_opts,
           next: [under: next_supervisor]
         ]
       ]}
    ]
    |> List.flatten()
    |> prepare_stages(Platform.App.Drive.Boot)
  end

  defp pg_stages(device) do
    task_supervisor = name(BootTask, device)
    pg_dir = pg_dir(device)
    port = pg_port_for_device(device)
    repo_name = repo_name(device)

    [
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
      {:step, name(RepoStarted, device),
       {@pg_repo_starter, name: repo_name, port: port, task_in: task_supervisor}
       |> exit_takes(30_000)},
      {:step, name(MigrationsRun, device),
       {@pg_migration_runner, repo_name: repo_name, task_in: task_supervisor}
       |> exit_takes(60_000)}
    ]
  end

  defp define_repo(device) do
    repo_name = repo_name(device)

    device
    |> drive_repo_config(pg_port_for_device(device))
    |> then(&Application.put_env(:platform, repo_name, &1))

    repo_module_content =
      quote do
        use Ecto.Repo,
          otp_app: :platform,
          adapter: Ecto.Adapters.Postgres
      end

    Module.create(repo_name, repo_module_content, Macro.Env.location(__ENV__))
  end

  defp mount_path(device), do: Path.join(@mount_path, device)
  defp pg_dir(device), do: device |> mount_path() |> Path.join("pg")
  defp repo_name(device), do: atom_name(Repo, device)

  defp atom_name(suffix, device) do
    "sd" <> <<index::bitstring-size(8)>> <> _ = device

    Module.concat([Platform.Dev, :"Sd#{index}", suffix])
  end

  defp name(stage, device) do
    Drive.registry_name(stage, device)
  end

  defp mount_options do
    [uid: Postgres.get_postgres_uid(), gid: Postgres.get_postgres_gid()]
  end
end
