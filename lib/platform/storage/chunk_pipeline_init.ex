defmodule Platform.Storage.ChunkPipelineInit do
  @moduledoc "Stage: start ChunkPipelineSupervisor for the internal drive after Electric is ready."

  use GracefulGenServer
  use Toolbox.OriginLog

  alias Chat.Data.File.ChunkPipelineSupervisor

  @impl true
  def on_init(opts) do
    next = Keyword.get(opts, :next)

    %{next: next}
    |> tap(fn _ -> send(self(), :start) end)
  end

  @impl GracefulGenServer
  def on_msg(:start, state) do
    {:ok, _pid} =
      DynamicSupervisor.start_child(
        Chat.RepoDynamicSupervisor,
        {ChunkPipelineSupervisor, drive_id: :internal, repo: Chat.Repo}
      )

    log("ChunkPipelineSupervisor started for internal drive", :info)
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
