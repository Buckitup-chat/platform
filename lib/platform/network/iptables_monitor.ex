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

    case {nat =~ "MASQUERADE", filter =~ "FORWARD" and filter =~ "wlan0"} do
      {true, true} ->
        log("iptables rules OK", :debug)

      {has_masquerade?, has_forward?} ->
        log(
          [
            "Missing iptables rules — MASQUERADE: ", to_string(has_masquerade?),
            ", FORWARD/wlan0: ", to_string(has_forward?),
            "\nNAT:\n", nat,
            "\nFILTER:\n", filter
          ],
          :warning
        )
    end
  end
end
