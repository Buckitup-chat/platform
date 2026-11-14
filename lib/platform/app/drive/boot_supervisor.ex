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
  alias Chat.Storage.Unit
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
    defp pg_port(_unit), do: Application.get_env(:chat, Chat.Repo)[:port]

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

    defp pg_port(unit), do: Unit.pg_port(unit)

    defp drive_repo_config(_device, port) do
      Application.get_env(:chat, Chat.Repo) |> Keyword.put(:port, port)
    end
  end

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
        at: Unit.root(device),
        mount_options: mount_options(),
        task_in: task_supervisor}
       |> exit_takes(15_000)},
      {:step, name(InternalDbReady, device), {InternalDbAwaiter, task_in: task_supervisor}},
      {Resolver,
       device: device,
       at: Unit.root(device),
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
    pg_unit =
      case resolution do
        {:role, role} -> if :pg in Role.capabilities(role), do: Unit.usb(device, role)
        _ -> nil
      end

    next_supervisor = name(Scenario, device)

    pg_opts =
      if pg_unit,
        do: %{port: pg_port(pg_unit), dir: Unit.path(pg_unit, :pg), repo: Unit.repo(pg_unit)}

    [
      if(pg_unit, do: pg_stages(pg_unit), else: []),
      use_next_stage(next_supervisor) |> exit_takes(90_000),
      {Decider,
       [
         device,
         [
           mounted: Unit.root(device),
           scenario: Decider.scenario(resolution),
           pg: pg_opts,
           next: [under: next_supervisor]
         ]
       ]}
    ]
    |> List.flatten()
    |> prepare_stages(Platform.App.Drive.Boot)
  end

  defp pg_stages(%Unit{id: device} = unit) do
    task_supervisor = name(BootTask, device)
    pg_dir = Unit.path(unit, :pg)
    run_dir = Unit.pg_run(unit)
    port = pg_port(unit)
    repo_name = Unit.repo(unit)

    [
      {:step, name(InitPg, device),
       {@pg_initializer,
        pg_dir: pg_dir, pg_port: port, run_dir: run_dir, task_in: task_supervisor}
       |> exit_takes(30_000)},
      {:stage, name(PgServer, device),
       {@pg_daemon,
        pg_dir: pg_dir,
        pg_port: port,
        run_dir: run_dir,
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

  # Repo, port and run dir derive from the device alone, so the repo is defined
  # before the role is resolved
  defp define_repo(device) do
    unit = device_unit(device)
    repo_name = Unit.repo(unit)

    device
    |> drive_repo_config(pg_port(unit))
    |> then(&Application.put_env(:platform, repo_name, &1))

    repo_module_content =
      quote do
        use Ecto.Repo,
          otp_app: :platform,
          adapter: Ecto.Adapters.Postgres
      end

    Module.create(repo_name, repo_module_content, Macro.Env.location(__ENV__))
  end

  defp device_unit(device), do: Unit.usb(device, :main)

  defp name(stage, device) do
    Drive.registry_name(stage, device)
  end

  defp mount_options do
    [uid: Postgres.get_postgres_uid(), gid: Postgres.get_postgres_gid()]
  end
end
