defmodule Platform.Storage.Repo.MigrationRunner do
  @moduledoc """
  Step module for running database migrations.
  This is a one-time operation that runs migrations and then propagates to next stage.
  """
  use GracefulGenServer, timeout: :timer.minutes(3)
  use OriginLog

  alias Platform.Tools.Postgres.LogicalReplicator

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
    log("Running migrations for repo #{inspect(repo_name)}", :info)

    %{ref: ref} =
      Task.Supervisor.async_nolink(task_supervisor, fn ->
        wait_for_repo_ready(repo_name)
        Chat.RepoStarter.run_migrations(repo_name)
      end)

    {:noreply, %{state | task_ref: ref}}
  end

  def on_msg(
        {ref, result},
        %{task_ref: ref, repo_name: repo_name} = state
      ) do
    Process.demonitor(ref, [:flush])

    case result do
      migrations when is_list(migrations) ->
        log("Migrations completed for #{inspect(repo_name)}, starting next stage", :info)
        ensure_electric_slot_if_needed(repo_name)

      error ->
        log("Migration task returned: #{inspect(error)}", :warning)
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
  def on_exit(_reason, _state), do: :ok

  defp wait_for_repo_ready(repo_name, attempts \\ 30) do
    1..attempts
    |> Enum.reduce_while(:timeout, fn i, _acc ->
      case repo_name.query("SELECT 1") do
        {:ok, _} ->
          {:halt, :ok}

        {:error, _} ->
          log("Waiting for #{inspect(repo_name)} to be ready (attempt #{i}/#{attempts})", :debug)
          Process.sleep(1000)
          {:cont, :timeout}
      end
    end)
    |> case do
      :ok -> :ok
      :timeout -> log("Timeout waiting for #{inspect(repo_name)} to be ready", :warning)
    end
  end

  defp ensure_electric_slot_if_needed(repo) do
    case LogicalReplicator.ensure_slot_on_source(repo, "electric_slot_default") do
      :ok ->
        :ok

      {:error, reason} ->
        log(
          "failed to ensure electric_slot_default on repo=#{inspect(repo)} reason=#{inspect(reason)}",
          :error
        )

        :ok
    end
  end
end
