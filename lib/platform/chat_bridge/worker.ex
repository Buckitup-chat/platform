defmodule Platform.ChatBridge.Worker do
  @moduledoc "Talks to Chat through PubSub"

  require Logger

  use GenServer

  alias Phoenix.PubSub
  alias Platform.ChatBridge.Lan
  alias Platform.ChatBridge.Logic

  @incoming_topic Application.compile_env!(:chat, :topic_to_platform)
  @outgoing_topic Application.compile_env!(:chat, :topic_from_platform)

  def start_link(opts) do
    GenServer.start_link(__MODULE__, :ok, Keyword.merge([name: __MODULE__], opts))
  end

  @impl true
  def init(_) do
    Process.send_after(self(), :init, 1000)

    {:ok, %{}}
  end

  @impl true
  def handle_info(:init, state) do
    PubSub.subscribe(Chat.PubSub, @incoming_topic)

    noreply(state)
  end

  def handle_info(message, state) do
    case message do
      :get_wifi_settings ->
        Logic.get_wifi_settings()

      {:set_wifi, ssid} ->
        Logic.set_wifi_settings(ssid)

      {:set_wifi, ssid, password} ->
        Logic.set_wifi_settings(ssid, password)

      :lan_ip ->
        Logic.get_lan_ip()

      :lan_profile ->
        Logic.get_lan_profile()

      :lan_known_profiles ->
        Logic.get_lan_known_profiles()

      {:lan_set_profile, profile} ->
        Logic.set_lan_profile(profile)

      {:lan_ip_and_mask, pid} ->
        {:to, pid, {:range, {Lan.get_ip_address(), Lan.get_ip_mask()}}}

      :get_device_log ->
        Logic.get_device_log()

      :unmount_main ->
        Logic.unmount_main()

      :get_gpio24_impedance_status ->
        Logic.get_gpio24_impedance_status()

      :toggle_gpio24_impendance ->
        Logic.toggle_gpio24_impendance()

      {:connect_to_weight_sensor, {type, name}, opts} ->
        Logic.connect_to_weight_sensor({type, name}, opts)

      {:upgrade_firmware, binary} ->
        Logic.upgrade_firmware(binary)
    end
    |> respond()

    noreply(state)
  rescue
    _ -> noreply(state)
  end

  defp noreply(x), do: {:noreply, x}

  defp respond({:to, pid, message}), do: send(pid, message)

  defp respond(message) do
    # Logger.info("Platform responds: " <> inspect(message, pretty: true))
    PubSub.broadcast(Chat.PubSub, @outgoing_topic, {:platform_response, message})
  end
end
