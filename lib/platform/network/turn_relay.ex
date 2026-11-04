defmodule Platform.Network.TurnRelay do
  @moduledoc """
  Runs one TURN UDP listener per LAN interface address via `Chat.Turn.LanRelay`.

  Follows VintageNet `addresses` and `config` of wlan0, eth0 and usb0. A
  listener starts as soon as its interface has an IPv4 address and restarts
  when the address or the allowed peer ranges change (eth0 lease or profile).
  """

  use GenServer
  use Toolbox.OriginLog

  alias Chat.Turn.LanRelay
  alias Platform.Network.TurnRelay.Plan

  @retry_ms 5_000
  @safety_ms 60_000

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  end

  @impl true
  def init(_) do
    Process.flag(:trap_exit, true)

    for iface <- Plan.ifaces(), property <- ["addresses", "config"] do
      VintageNet.subscribe(["interface", iface, property])
    end

    send(self(), :reconcile)
    :timer.send_interval(@safety_ms, :reconcile)
    {:ok, %{running: %{}}}
  end

  @impl true
  def handle_info(:reconcile, state), do: {:noreply, reconcile(state)}

  def handle_info({VintageNet, ["interface", _iface, _property], _old, _new, _meta}, state) do
    {:noreply, reconcile(state)}
  end

  @impl true
  def terminate(_reason, %{running: running}) do
    running |> Plan.own_ips() |> Enum.each(&LanRelay.stop/1)
  end

  defp reconcile(%{running: running} = state) do
    desired = vintage_net_state() |> Plan.desired()
    {to_stop, to_start} = Plan.diff(running, desired)
    own_ips = Plan.own_ips(desired)

    Enum.each(to_stop, &LanRelay.stop/1)
    kept = Map.filter(running, fn {iface, entry} -> desired[iface] == entry end)

    to_start
    |> Enum.reduce(kept, fn {iface, %{ip: ip, allowed: allowed} = entry}, acc ->
      case LanRelay.start(ip, own_ips, allowed) do
        :ok -> Map.put(acc, iface, entry)
        {:error, _} -> acc
      end
    end)
    |> tap(&schedule_retry(map_size(&1) < map_size(desired)))
    |> then(&%{state | running: &1})
  end

  defp schedule_retry(true), do: Process.send_after(self(), :reconcile, @retry_ms)
  defp schedule_retry(false), do: :ok

  defp vintage_net_state do
    Map.new(Plan.ifaces(), fn iface ->
      {iface,
       %{
         addresses: VintageNet.get(["interface", iface, "addresses"], []),
         config: VintageNet.get_configuration(iface)
       }}
    end)
  end
end
