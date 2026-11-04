defmodule Platform.Network.TurnRelay.PlanTest do
  use ExUnit.Case, async: true

  alias Chat.Turn.Cidr
  alias Platform.Network.TurnRelay.Plan

  @wlan_ip {192, 168, 25, 1}
  @eth_ip {192, 168, 24, 1}
  @lease {10, 1, 2, 3}

  describe "desired/1" do
    test "DHCP server interfaces allow their pool" do
      desired = Plan.desired(%{"wlan0" => wlan0(), "eth0" => eth0_no_internet()})

      assert desired["wlan0"] == %{ip: @wlan_ip, allowed: pool(25)}
      assert desired["eth0"] == %{ip: @eth_ip, allowed: pool(24)}
    end

    test "eth0 internet allows the network of its lease" do
      desired = Plan.desired(%{"eth0" => eth0_internet(@lease)})

      assert desired["eth0"] == %{ip: @lease, allowed: [{{10, 1, 0, 0}, 16}]}
    end

    test "interfaces without a usable IPv4 address are omitted" do
      link_local = iface([%{family: :inet, address: {169, 254, 3, 4}, prefix_length: 16}], %{})
      ipv6_only = iface([%{family: :inet6, address: {0xFE80, 0, 0, 0, 0, 0, 0, 1}}], %{})

      assert Plan.desired(%{"usb0" => link_local, "eth0" => ipv6_only, "wlan0" => iface([], %{})}) ==
               %{}
    end

    test "ZeroTier and unknown interfaces are never relayed" do
      zt = iface([inet({10, 147, 0, 5}, 16)], %{})

      assert Plan.desired(%{"ztabcdef12" => zt, "lo" => zt}) == %{}
    end
  end

  describe "diff/2" do
    test "eth0 lease change stops the old address and starts the new one" do
      current = Plan.desired(%{"wlan0" => wlan0(), "eth0" => eth0_internet(@lease)})
      desired = Plan.desired(%{"wlan0" => wlan0(), "eth0" => eth0_internet({10, 1, 9, 9})})

      assert {[@lease], [{"eth0", %{ip: {10, 1, 9, 9}}}]} = Plan.diff(current, desired)
    end

    test "switch to no_internet restarts eth0 with the pool" do
      current = Plan.desired(%{"eth0" => eth0_internet(@lease)})
      desired = Plan.desired(%{"eth0" => eth0_no_internet()})

      assert {[@lease], [{"eth0", %{ip: @eth_ip, allowed: allowed}}]} =
               Plan.diff(current, desired)

      assert allowed == pool(24)
    end

    test "unchanged interfaces are left alone" do
      current = Plan.desired(%{"wlan0" => wlan0()})

      assert Plan.diff(current, current) == {[], []}
      assert Plan.diff(%{}, current) == {[], [{"wlan0", current["wlan0"]}]}
      assert Plan.diff(current, %{}) == {[@wlan_ip], []}
    end
  end

  test "own_ips lists every relay address" do
    desired = Plan.desired(%{"wlan0" => wlan0(), "eth0" => eth0_no_internet()})

    assert Enum.sort(Plan.own_ips(desired)) == Enum.sort([@wlan_ip, @eth_ip])
  end

  # Helpers

  defp wlan0, do: iface([inet(@wlan_ip, 24)], dhcpd(25))
  defp eth0_no_internet, do: iface([inet(@eth_ip, 24)], dhcpd(24))
  defp eth0_internet(lease), do: iface([inet(lease, 16)], %{ipv4: %{method: :dhcp}})

  defp iface(addresses, config), do: %{addresses: addresses, config: config}

  defp inet(ip, prefix_length), do: %{family: :inet, address: ip, prefix_length: prefix_length}

  defp dhcpd(c), do: %{dhcpd: %{start: {192, 168, c, 10}, end: {192, 168, c, 250}}}

  defp pool(c), do: Cidr.pool({192, 168, c, 10}, {192, 168, c, 250})
end
