defmodule Platform.Emulator.Drive.RepoStarter do
  @moduledoc """
  Host stand-in for `Platform.Storage.Pg.DbCreator` + `Platform.Storage.Repo.Starter`.

  There is no per-drive PostgreSQL server on host, so the drive repo points at
  its own database on the local server (see `BootSupervisor`). This stage
  creates that database if needed and keeps the repo alive.
  """
  use GracefulGenServer, timeout: :timer.minutes(1)
  use Toolbox.OriginLog

  alias Ecto.Adapters.Postgres

  @impl true
  def on_init(opts) do
    next = opts |> Keyword.fetch!(:next)

    %{
      repo_name: opts |> Keyword.fetch!(:name),
      next_specs: next |> Keyword.fetch!(:run),
      next_supervisor: next |> Keyword.fetch!(:under)
    }
    |> tap(fn _ -> send(self(), :start) end)
  end

  @impl true
  def on_msg(:start, %{repo_name: repo_name} = state) do
    config = Application.fetch_env!(:platform, repo_name)

    case Postgres.storage_up(config) do
      :ok -> :ok
      {:error, :already_up} -> :ok
    end

    {:ok, _pid} = repo_name.start_link()
    log("#{inspect(repo_name)} started on database #{config[:database]}", :info)

    Platform.start_next_stage(state.next_supervisor, state.next_specs)
    {:noreply, state}
  end

  @impl true
  def on_exit(_reason, _state), do: :ok
end
