defmodule Platform.Storage.ChunkPipelineInit do
  @moduledoc "Stage: start ChunkPipelineSupervisor for the internal drive after Electric is ready."

  use GracefulGenServer
  use Toolbox.OriginLog

  alias Chat.Data.File.ChunkPipelineSupervisor

  @impl true
  def on_init(opts) do
    next = Keyword.get(opts, :next)
    drive_id = Keyword.get(opts, :drive_id, :internal)
    repo = Keyword.get(opts, :repo, Chat.Repo)

    %{next: next, drive_id: drive_id, repo: repo}
    |> tap(fn _ -> send(self(), :start) end)
  end

  @impl GracefulGenServer
  def on_msg(:start, state) do
    {:ok, _pid} =
      DynamicSupervisor.start_child(
        Chat.RepoDynamicSupervisor,
        {ChunkPipelineSupervisor, drive_id: state.drive_id, repo: state.repo}
      )

    log("ChunkPipelineSupervisor started for #{inspect(state.drive_id)} drive", :info)
    send(self(), :done)
    {:noreply, state}
  end

  #AI: see 6 lines bellow. single clause here
  def on_msg(:done, %{next: nil} = state), do: {:noreply, state}

  def on_msg(:done, %{next: next} = state) do
    Platform.start_next_stage(next[:under], next[:run])
    {:noreply, state}
  end

  @impl true
  def on_exit(_reason, _state), do: :ok
end
