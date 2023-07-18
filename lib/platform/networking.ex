defmodule Platform.Networking.System do
  @moduledoc """
  Wrap system commands running
  """

  def cmd([head | tail]) do
    System.cmd(head, tail)
  end
end

defmodule Platform.Networking.Utils do
  @moduledoc """
  Networking utilities.
  """

  def ipv4_string_to_tuple({_, _, _, _} = tuple), do: tuple

  def ipv4_string_to_tuple(ip_string) do
    [a, b, c, d] =
      String.split(ip_string, ".")
      |> Enum.map(&String.to_integer/1)

    {a, b, c, d}
  end
end

defmodule Platform.Networking do
  @moduledoc "Networking functions"

  import Platform.Networking.System, only: [cmd: 1]
  import Platform.Networking.Utils, only: [ipv4_string_to_tuple: 1]

  @doc """
  Adds static alias to already up network interface
  """
  def add_static_alias(interface, ip_cidr, gateaway_ip, dns_ips \\ []) do
    if is_up?(interface) do
      interface
      |> add_ip(ip_cidr)
      |> add_gateaway(gateaway_ip)
      |> add_dns(dns_ips |> set_if_empty([gateaway_ip]))
    end
  end

  defp is_up?(iface) do
    cmd(["ip", "link", "show", iface, "up"])
    |> case do
      {str, 0} -> str |> String.contains?(iface)
      _ -> false
    end
  end

  defp add_ip(iface, cidr) do
    {_, 0} = cmd(["ip", "addr", "add", cidr, "dev", iface])
    iface
  end

  defp add_gateaway(iface, gw) do
    {_, 0} = cmd(["ip", "route", "add", "default", "via", gw, "dev", iface, "metric", "20"])
    iface
  end

  defp add_dns(iface, ip_list) do
    current_servers =
      PropertyTable.get(VintageNet, ["name_servers"])
      |> Enum.filter(&match?(%{from: [^iface]}, &1))
      |> Enum.map(&Map.get(&1, :address))
      |> Enum.reject(&is_nil/1)

    ip_list
    |> Enum.map(&ipv4_string_to_tuple/1)
    |> then(&(current_servers ++ &1))
    |> then(&VintageNet.NameResolver.setup(iface, nil, &1))

    iface
  end

  defp set_if_empty(list, default) do
    if Enum.empty?(list) do
      default
    else
      list
    end
  end
end
