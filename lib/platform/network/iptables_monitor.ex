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

    has_masquerade? = nat =~ "MASQUERADE"
    has_forward? = filter =~ "FORWARD" and filter =~ "wlan0"
    has_input? = filter =~ "INPUT" and filter =~ "RELATED,ESTABLISHED"
    has_ip_forward? = ip_forward =~ "= 1"

    missing =
      [{has_ip_forward?, "ip_forward"},
       {has_masquerade?, "MASQUERADE"},
       {has_forward?, "FORWARD/wlan0"},
       {has_input?, "INPUT/RELATED,ESTABLISHED"}]
      |> Enum.reject(&elem(&1, 0))
      |> Enum.map(&elem(&1, 1))

    case missing do
      [] ->
        log("Inet is ok", :debug)

      _ ->
        log(["Inet warning: missing ", Enum.join(missing, ", ")], :warning)
    end
  end
end
