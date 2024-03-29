defmodule Platform.ChatBridge.Lan do
  @moduledoc "LAN interface functions"

  @iface "eth0"

  def get_profile do
    get_current_iface_setting(@iface)
    |> detect_know_profile()
  end

  def set_profile(profile) do
    get_known_profile(profile)
    |> set_iface_setting(@iface)
  end

  def get_ip_address do
    get_iface_property(@iface, :addr)
  end

  def get_ip_mask do
    get_iface_property(@iface, :netmask)
  end

  def profiles do
    configured_profiles()
    |> Keyword.keys()
  end

  defp get_current_iface_setting(iface) do
    VintageNet.get_configuration(iface)
  end

  defp get_iface_property(iface, property) do
    {:ok, addr_list} = :inet.getifaddrs()

    addr_list
    |> Enum.find_value(fn {interface, list} -> interface == to_charlist(iface) && list end)
    |> Enum.find(&match?({^property, {_, _, _, _}}, &1))
    |> elem(1)
    |> Tuple.to_list()
    |> Enum.map_join(".", &to_string/1)
  end

  defp detect_know_profile(config) do
    configured_profiles()
    |> Enum.find_value(:unknown, fn
      {profile, ^config} -> profile
      _ -> nil
    end)
  end

  defp get_known_profile(profile) do
    configured_profiles()
    |> Keyword.fetch!(profile)
  end

  defp set_iface_setting(setting, iface) do
    VintageNet.configure(iface, setting)
  end

  defp configured_profiles do
    Application.get_env(:platform, :lan_profiles)
  end
end
