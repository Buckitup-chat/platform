defmodule Platform.ChatBridge.Wifi do
  @moduledoc "Wi-fi functions"

  @iface "wlan0"

  def get_wifi_settings do
    wlan_config()
    |> wifi_config()
    |> ssid_and_password()
  end

  def set_wifi_settings(ssid, password \\ nil) do
    wlan_config()
    |> inject_ssid(ssid)
    |> inject_password(password)
    |> apply_wlan_config()
  end

  defp wlan_config do
    VintageNet.get_configuration(@iface)
  end

  defp ssid_and_password(%{ssid: ssid, psk: hex_psk} = _wifi) do
    %{ssid: ssid, password: get_psk_env(default: hex_psk)}
  end

  defp inject_ssid(config, ssid), do: inject_config(config, &Map.put(&1, :ssid, ssid))
  defp inject_password(config, nil), do: inject_config(config, &Map.drop(&1, [:psk]))
  defp inject_password(config, password), do: inject_config(config, &Map.put(&1, :psk, password))

  defp apply_wlan_config(config) do
    VintageNet.configure(@iface, config)
  end

  defp inject_config(config, action) do
    config
    |> wifi_config()
    |> then(action)
    |> set_wifi_in_wlan(config)
  end

  defp wifi_config(config) do
    config
    |> get_in([:vintage_net_wifi, :networks])
    |> List.first()
  end

  defp set_wifi_in_wlan(wifi, wlan) do
    put_in(wlan, [:vintage_net_wifi, :networks], [wifi])
  end

  def get_psk_env(default: hex_password) do
    with {:ok, configs} <- {:ok, Application.get_env(:vintage_net, :config)},
         {:ok, iface_config} <- find_iface_config(configs, @iface),
         [%{psk: psk} | _] <- get_in(iface_config, [:vintage_net_wifi, :networks]) do
      psk
    else
      _ -> hex_password
    end
  end

  defp find_iface_config(configs, iface) do
    Enum.find_value(configs, {:error, :not_found}, fn
      {^iface, config} -> {:ok, config}
      _ -> false
    end)
  end
end
