defmodule Platform.App.Drive.PostgresSupervisor do
  @moduledoc """
  DEPRECATED: This module has been replaced by modular step/stage approach.
  
  The functionality has been split into:
  - Platform.Storage.Pg.Initializer (step: init_pg)
  - Platform.Storage.Pg.Daemon (stage: start_pg_server)
  - Platform.Storage.Pg.DbCreator (step: ensure_db_created)
  
  Used in Platform.App.Drive.BootSupervisor.
  
  Note: Chat.Repo and migrations remain in the Chat domain.
  """

  use Supervisor

  alias Platform.Tools.Postgres

  def start_link(opts) do
    {name, init_opts} = Keyword.pop(opts, :name)

    Supervisor.start_link(__MODULE__, init_opts, name: name, max_restarts: 1, max_seconds: 15)
  end

  @impl true
  def init(opts) do
    pg_dir = opts |> Keyword.fetch!(:pg_dir)
    port = opts |> Keyword.fetch!(:pg_port)
    repo_name = opts |> Keyword.fetch!(:repo)

    children = [
      {Task, fn -> Postgres.initialize(pg_dir: pg_dir, pg_port: port) end},
      Postgres.daemon_spec(pg_dir: pg_dir, pg_port: port),
      {Task, fn -> Postgres.ensure_db_exists("chat", pg_port: port) end},
      {Chat.Repo, name: repo_name, port: port},
      {Task,
       fn ->
         Chat.Repo.with_dynamic_repo(repo_name, fn -> Chat.RepoStarter.run_migrations() end)
       end}
    ]

    Supervisor.init(children, strategy: :rest_for_one, max_restarts: 1, max_seconds: 5)
  end
end
