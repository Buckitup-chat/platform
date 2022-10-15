defmodule Platform.Storage.MainReplicator do
  @moduledoc "GenServer to replicate main to internal every 5min or so"

  use GenServer

  require Logger

  alias Platform.Storage.Logic

  @interval :timer.seconds(307)

  defstruct [:timer, enabled: false]

  def start do
    __MODULE__
    |> GenServer.call(:start)
  end

  def stop do
    __MODULE__
    |> GenServer.call(:stop)
  end

  def start_link(opts) do
    GenServer.start_link(__MODULE__, :ok, Keyword.merge([name: __MODULE__], opts))
  end

  @impl true
  def init(_) do
    {:ok, %__MODULE__{}}
  end

  @impl true
  def handle_call(:start, _, state) do
    case state do
      %{timer: nil} -> %__MODULE__{timer: schedule(), enabled: true}
      _ -> %{state | enabled: true}
    end
    |> then(&{:reply, :ok, &1})
  end

  def handle_call(:stop, _, state) do
    if state.timer do
      Process.cancel_timer(state.timer)
    end

    {:reply, :ok, %__MODULE__{}}
  end

  @impl true
  def handle_info(:tick, %{enabled: true} = state) do
    Logic.replicate_main_to_internal()

    {:noreply, %{state | timer: schedule()}}
  rescue
    e ->
      Logger.warn(" [platform] error replicating: #{inspect(e)}")
      {:noreply, %{state | timer: schedule()}}
  end

  defp schedule do
    Process.send_after(self(), :tick, @interval)
  end
end
