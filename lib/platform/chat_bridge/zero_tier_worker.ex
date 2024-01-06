defmodule Platform.ChatBridge.ZeroTierWorker do
  @moduledoc "ZeroTier worker"
  # cmd "zerotier-cli -D/root/zt info"

  require Logger
  use GenServer
  import Tools.GenServerHelpers

  alias Phoenix.PubSub

  @topic Application.compile_env!(:chat, :zero_tier_topic)

  def start_link(opts) do
    GenServer.start_link(__MODULE__, :ok, Keyword.merge([name: __MODULE__], opts))
  end

  @impl true
  def init(_) do
    {:ok, %{}, {:continue, :init}}
  end

  def handle_continue(:init, state) do
    PubSub.subscribe(Chat.PubSub, @topic)
    noreply(state)
  end

  def handle_info({command, pid}, state) do
    command
    |> parse
    |> run
    |> respond(command, pid)

    noreply(state)
  end

  defp parse(command) do
    case command do
      :info -> "info"
      :list_networks -> "listnetworks"
      {:join_network, id} -> "join #{id}"
      {:leave_network, id} -> "leave #{id}"
    end
    |> then(&"zerotier-cli -D/root/zt -j #{&1}")
  end

  defp run(command) do
    {out, code} = System.cmd(command)

    if code != 0 do
      Logger.error("ZeroTier: #{out}")
      {:error, out}
    else
      {:ok, out}
    end
  end

  defp respond(response, command, pid) do
    send(pid, {command, response})
  end
end
