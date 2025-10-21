defmodule Platform.Storage.Repo.Starter do
  @moduledoc """
  Stage module for starting Chat.Repo with a dynamic name.
  This is a long-running stage that keeps the repo alive and propagates to next stage.
  """
  use GracefulGenServer, timeout: :timer.minutes(3)

  require Logger

  @impl true
  def on_init(opts) do
    next = opts |> Keyword.fetch!(:next)

    %{
      repo_name: opts |> Keyword.fetch!(:name),
      port: opts |> Keyword.fetch!(:port),
      next_specs: next |> Keyword.fetch!(:run),
      next_supervisor: next |> Keyword.fetch!(:under),
      repo_pid: nil
    }
    |> tap(fn _ -> send(self(), :start) end)
  end

  @impl true
  def on_msg(
        :start,
        %{
          repo_name: repo_name,
          port: port,
          next_specs: next_specs,
          next_supervisor: next_supervisor
        } = state
      ) do
    Logger.info("Starting Chat.Repo with name #{inspect(repo_name)} on port #{port}")

    # Start the repo as a supervised child
    {:ok, pid} = Chat.Repo.start_link(name: repo_name, port: port)

    Logger.info("Chat.Repo started successfully, starting next stage")
    Platform.start_next_stage(next_supervisor, next_specs)

    {:noreply, %{state | repo_pid: pid}}
  end

  @impl true
  def on_exit(_reason, %{repo_name: repo_name}) do
    Logger.info("Repo starter stage exiting for #{inspect(repo_name)}")
    # The repo will be stopped by the supervisor
    :ok
  end
end
