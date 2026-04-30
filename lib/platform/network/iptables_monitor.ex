defmodule Platform.Network.IptablesMonitor do
  @moduledoc """
  Monitors iptables NAT/forwarding rules.
  Checks periodically (every 60s) and on VintageNet connection changes.
  Only verifies rules when LAN profile is :internet (eth0 has upstream).
  """

  use GenServer
  use Toolbox.OriginLog

  @check_interval_ms 60_000

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  end

  @impl true
  def init(_) do
    VintageNet.subscribe(["interface", "eth0", "connection"])
    VintageNet.subscribe(["interface", "wlan0", "connection"])
    send(self(), :check)
    {:ok, %{}}
  end

  @impl true
  def handle_info(:check, state) do
    check_rules()
    Process.send_after(self(), :check, @check_interval_ms)
    {:noreply, state}
  end

  @impl true
  def handle_info({VintageNet, ["interface", iface, "connection"], _old, new, _meta}, state) do
    log(["#{iface} connection changed to ", inspect(new)], :info)
    check_rules()
    {:noreply, state}
  end

  defp check_rules do
    case Platform.ChatBridge.Lan.get_profile() do
      :internet -> verify_iptables()
      profile -> log(["LAN profile is ", inspect(profile), ", skipping iptables check"], :debug)
    end
  end

  defp verify_iptables do
    {nat, _} = System.cmd("iptables", ["-t", "nat", "-S"])
    {filter, _} = System.cmd("iptables", ["-S"])
    {ip_forward, _} = System.cmd("sysctl", ["net.ipv4.ip_forward"])

    missing =
      [
        {ip_forward =~ "= 1", :ip_forward},
        {nat =~ "MASQUERADE", :masquerade},
        {filter =~ "FORWARD" and filter =~ "wlan0", :forward},
        {filter =~ "INPUT" and filter =~ "RELATED,ESTABLISHED", :input}
      ]
      |> Enum.reject(&elem(&1, 0))
      |> Enum.map(&elem(&1, 1))

    case missing do
      [] ->
        log("Inet is ok", :debug)

      _ ->
        log(["Inet warning: missing ", inspect(missing)], :warning)
        recover_iptables(missing)
    end
  end

  defp recover_iptables(missing) do
    Enum.each(missing, &apply_rule/1)
    log(["Recovered iptables rules: ", inspect(missing)], :info)
  end

  defp apply_rule(:ip_forward),
    do: System.cmd("sysctl", ["-w", "net.ipv4.ip_forward=1"])

  defp apply_rule(:masquerade),
    do: System.cmd("iptables", ["-t", "nat", "-A", "POSTROUTING", "-o", "eth0", "-j", "MASQUERADE"])

  defp apply_rule(:forward),
    do: System.cmd("iptables", ["--append", "FORWARD", "--in-interface", "wlan0", "-j", "ACCEPT"])

  defp apply_rule(:input),
    do: System.cmd("iptables", ["-A", "INPUT", "-i", "eth0", "-m", "state", "--state", "RELATED,ESTABLISHED", "-j", "ACCEPT"])
end
