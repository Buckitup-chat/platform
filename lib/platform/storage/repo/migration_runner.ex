defmodule Platform.Storage.Repo.MigrationRunner do
  @moduledoc """
  Step module for running database migrations.
  This is a one-time operation that runs migrations and then propagates to next stage.
  """
  use GracefulGenServer, timeout: :timer.minutes(3)

  require Logger

  @impl true
  def on_init(opts) do
    next = opts |> Keyword.fetch!(:next)

    %{
      repo_name: opts |> Keyword.fetch!(:repo_name),
      task_supervisor: opts |> Keyword.fetch!(:task_in),
      next_specs: next |> Keyword.fetch!(:run),
      next_supervisor: next |> Keyword.fetch!(:under),
      task_ref: nil
    }
    |> tap(fn _ -> send(self(), :start) end)
  end

  @impl true
  def on_msg(
        :start,
        %{
          repo_name: repo_name,
          task_supervisor: task_supervisor
        } = state
      ) do
    Logger.info("Running migrations for repo #{inspect(repo_name)}")

    %{ref: ref} =
      Task.Supervisor.async_nolink(task_supervisor, fn ->
        Chat.RepoStarter.run_migrations(repo_name)
      end)

    {:noreply, %{state | task_ref: ref}}
  end

  @impl true
  def on_msg(
        {ref, result},
        %{task_ref: ref, repo_name: repo_name} = state
      ) do
    Process.demonitor(ref, [:flush])

    case result do
      migrations when is_list(migrations) ->
        Logger.info("Migrations completed for #{inspect(repo_name)}, starting next stage")

      error ->
        Logger.warning("Migration task returned: #{inspect(error)}")
    end

    send(self(), :migrations_done)
    {:noreply, state}
  end

  @impl true
  def on_msg(
        :migrations_done,
        %{next_specs: next_specs, next_supervisor: next_supervisor} = state
      ) do
    Platform.start_next_stage(next_supervisor, next_specs)
    {:noreply, state}
  end

  @impl true
  def on_exit(_reason, _state) do
    # No cleanup needed for migrations
    :ok
  end
end
