defmodule Platform.Network.TurnRelay.Plan do
  @moduledoc """
  Pure planning for device TURN relays: which LAN address gets a listener and
  which peer ranges it may reach.

  Input is VintageNet state per interface. An interface serving DHCP allows its
  pool; a DHCP client (eth0 `internet`) allows the network of its lease.
  ZeroTier is never relayed.
  """

  alias Chat.Turn.Cidr

  @ifaces ~w(wlan0 eth0 usb0)
  @link_local {{169, 254, 0, 0}, 16}

  @type entry :: %{ip: :inet.ip4_address(), allowed: [Cidr.subnet()]}
  @type iface_state :: %{addresses: [map()], config: map()}

  def ifaces, do: @ifaces

  @spec desired(%{String.t() => iface_state()}) :: %{String.t() => entry()}
  def desired(ifaces) do
    for {iface, %{addresses: addresses, config: config}} <- ifaces,
        iface in @ifaces,
        address = ipv4_address(addresses),
        address != nil,
        into: %{},
        do: {iface, %{ip: address.address, allowed: allowed(address, config)}}
  end

  @spec own_ips(%{String.t() => entry()}) :: [:inet.ip4_address()]
  def own_ips(desired), do: desired |> Map.values() |> Enum.map(& &1.ip)

  @doc "Relay ips to stop and interfaces to (re)start to move from `current` to `desired`"
  @spec diff(%{String.t() => entry()}, %{String.t() => entry()}) ::
          {[:inet.ip4_address()], [{String.t(), entry()}]}
  def diff(current, desired) do
    changed? = fn iface -> Map.get(current, iface) != Map.get(desired, iface) end

    to_stop =
      for {iface, %{ip: ip}} <- current, changed?.(iface), do: ip

    to_start =
      for {iface, entry} <- desired, changed?.(iface), do: {iface, entry}

    {to_stop, to_start}
  end

  defp ipv4_address(addresses) do
    Enum.find(addresses, fn
      %{family: :inet, address: ip} -> not Cidr.contains?(@link_local, ip)
      _ -> false
    end)
  end

  defp allowed(address, config) do
    case config do
      %{dhcpd: %{start: first, end: last}} -> Cidr.pool(first, last)
      _ -> [Cidr.network(address.address, address.prefix_length)]
    end
  end
end
