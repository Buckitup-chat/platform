defmodule Platform.Storage.Repo.Starter do
  @moduledoc """
  Stage module for starting Chat.Repo with a dynamic name.
  This is a long-running stage that keeps the repo alive and propagates to next stage.
  """
  use GracefulGenServer, timeout: :timer.minutes(3)
  use Toolbox.OriginLog

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
    log("Starting #{inspect(repo_name)} on port #{port}", :info)

    {:ok, pid} =
      Application.get_env(:chat, Chat.Repo)
      |> Keyword.put(:port, port)
      |> repo_name.start_link()

    log("Chat.Repo started successfully, starting next stage", :info)
    Platform.start_next_stage(next_supervisor, next_specs)

    {:noreply, %{state | repo_pid: pid}}
  end

  @impl true
  def on_exit(_reason, %{repo_name: repo_name}) do
    log("Repo starter stage exiting for #{inspect(repo_name)}", :info)
    :ok
  end
end
