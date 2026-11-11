defmodule Platform.Emulator.Drive.MigrationRunner do
  @moduledoc """
  Host stand-in for `Platform.Storage.Repo.MigrationRunner`.

  Runs chat migrations on the drive repo, but skips the Electric replication
  slot: slots are cluster-wide and would pin WAL on the developer's server.
  """
  use GracefulGenServer, timeout: :timer.minutes(1)
  use Toolbox.OriginLog

  @impl true
  def on_init(opts) do
    next = opts |> Keyword.fetch!(:next)

    %{
      repo_name: opts |> Keyword.fetch!(:repo_name),
      next_specs: next |> Keyword.fetch!(:run),
      next_supervisor: next |> Keyword.fetch!(:under)
    }
    |> tap(fn _ -> send(self(), :start) end)
  end

  @impl true
  def on_msg(:start, %{repo_name: repo_name} = state) do
    # Every emulated drive migrates from scratch; per-migration logs would only flood
    :chat
    |> Application.app_dir("priv/repo/migrations")
    |> then(&Ecto.Migrator.run(repo_name, &1, :up, all: true, log: false))

    Platform.start_next_stage(state.next_supervisor, state.next_specs)
    {:noreply, state}
  end

  @impl true
  def on_exit(_reason, _state), do: :ok
end
