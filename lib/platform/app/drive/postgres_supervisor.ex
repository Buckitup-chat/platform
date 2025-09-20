defmodule Platform.App.Drive.PostgresSupervisor do
  @moduledoc "Starts Posrges server from the drive"

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
