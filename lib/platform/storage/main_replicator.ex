defmodule Platform.Storage.MainReplicator do
  @moduledoc "GenServer to replicate main to internal every 5min or so"

  use GenServer

  require Logger

  alias Platform.Storage.Logic

  @interval :timer.seconds(307)

  def start_link(opts) do
    GenServer.start_link(__MODULE__, :ok, Keyword.merge([name: __MODULE__], opts))
  end

  @impl true
  def init(_) do
    {:ok, schedule()}
  end

  @impl true
  def handle_info(:tick, _) do
    Logic.replicate_main_to_internal()

    {:noreply, schedule()}
  rescue
    e ->
      Logger.warning(" [platform] error replicating: #{inspect(e)}")
      {:noreply, schedule()}
  end

  defp schedule do
    Process.send_after(self(), :tick, @interval)
  end
end
