defmodule Platform.ChatBridge.Logic do
  @moduledoc "Logic for Chat Admin panel"

  alias Platform.Tools.Fwup

  alias Platform.ChatBridge.Lan
  alias Platform.ChatBridge.Wifi

  def get_wifi_settings do
    Wifi.get_wifi_settings()
    |> mark(:wifi_settings)
  rescue
    _ -> error(:getting_wifi_settings)
  end

  def set_wifi_settings(ssid, password \\ nil) do
    Wifi.set_wifi_settings(ssid, password)
    |> mark(:updated_wifi_settings)
  rescue
    _ -> error(:updating_wifi_settings)
  end

  def get_lan_profile do
    Lan.get_profile() |> mark(:lan_profile)
  rescue
    _ -> error(:getting_lan_profile)
  end

  def get_lan_ip do
    Lan.get_ip() |> mark(:lan_ip)
  rescue
    _ -> error(:getting_lan_ip)
  end

  def set_lan_profile(profile) do
    Lan.set_profile(profile) |> mark(:updated_lan_profile)
  rescue
    _ -> error(:updating_lan_profile)
  end

  def get_device_log do
    ram_log =
      case RamoopsLogger.read() do
        {:ok, dump} -> dump |> String.replace("\n\n", "\n")
        _ -> nil
      end

    {ram_log, RingLogger.get()}
    |> mark(:device_log)
  end

  def unmount_main do
    if Chat.Db.Common.get_chat_db_env(:mode) == :main do
      Chat.Db.MainDb
      |> CubDB.data_dir()
      |> Chat.Db.Maintenance.path_to_device()
      |> then(fn
        "/dev/" <> device -> device
        "/" <> device -> device
        device -> device
      end)
      |> Platform.UsbDrives.Drive.terminate()

      :unmounted
    else
      :ignored
    end
    |> mark(:unmounted_main)
  end

  def get_gpio24_impedance_status do
    {:ok, gpio} = Circuits.GPIO.open(24, :output)

    Circuits.GPIO.read(gpio)
    |> mark(:gpio24_impedance_status)
  end

  def toggle_gpio24_impendance do
    {:ok, gpio} = Circuits.GPIO.open(24, :output)
    new_value = if Circuits.GPIO.read(gpio) == 1, do: 0, else: 1

    :ok = Circuits.GPIO.write(gpio, new_value)
    {:gpio24_impedance_status, new_value}
  end

  def connect_to_weight_sensor({type, name}, opts) do
    Platform.Sensor.Weigh.poll(type, name, opts)
    |> mark(:weight_sensor_connection)
  end

  def upgrade_firmware(binary) do
    case Fwup.upgrade(binary) do
      :ok -> :firmware_upgraded
      _ -> error(:firmware_upgrade_failed)
    end
  end

  defp mark(x, label), do: {label, x}
  defp error(x), do: {:error, x}
end
