defmodule Platform.ChatBridge.Logic do
  @moduledoc "Logic for Chat Admin panel"

  @iface "wlan0"

  def get_wifi_settings do
    wlan_config()
    |> wifi_config()
    |> ssid_and_password()
    |> mark(:wifi_settings)
  rescue
    _ -> error(:getting_wifi_settings)
  end

  def set_wifi_settings(ssid, password \\ nil) do
    wlan_config()
    |> inject_ssid(ssid)
    |> inject_password(password)
    |> apply_wlan_config()
    |> mark(:updated_wifi_settings)
  rescue
    _ -> error(:updating_wifi_settings)
  end

  def get_device_log do
    RingLogger.get()
    |> mark(:device_log)
  end

  defp wlan_config do
    VintageNet.get_configuration(@iface)
  end

  defp ssid_and_password(wifi) do
    %{ssid: wifi.ssid, password: wifi.psk}
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

  defp mark(x, label), do: {label, x}
  defp error(x), do: {:error, x}
end
