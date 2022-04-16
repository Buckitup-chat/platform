defmodule Platform.Sync do
  @moduledoc """
  SystemRegistry.match(%{state: %{"subsystems" => %{"block" => :_}}}) 
  |> get_in([:state, "subsystems", "block"]) 
  |> Enum.filter(fn x -> Enum.at(x, 3) == "scb" edn )

  [
    [:state, "devices", "platform", "scb", "fd500000.pcie", "pci0000:00",
     "0000:00:00.0", "0000:01:00.0", "usb1", "1-1", "1-1.1", "1-1.1:1.0", "host0",
     "target0:0:0", "0:0:0:0", "block", "sda", "sda1"],
    [:state, "devices", "platform", "scb", "fd500000.pcie", "pci0000:00",
     "0000:00:00.0", "0000:01:00.0", "usb1", "1-1", "1-1.1", "1-1.1:1.0", "host0",
     "target0:0:0", "0:0:0:0", "block", "sda"]


    {:system_registry, :global, %{}}


    iex(42)> cmd "mkdir -p /root/media/sda1"
    iex(43)> cmd "mount /dev/sda1 /root/media/sda1"
    iex(44)> cmd "umount /dev/sda1"

  iex(17)> cat "/sys/block/sda/uevent"
  MAJOR=8
  MINOR=0
  DEVNAME=sda
  DEVTYPE=disk
  iex(18)> cat "/sys/block/sda/sda1/uevent"
  MAJOR=8
  MINOR=1
  DEVNAME=sda1
  DEVTYPE=partition
  PARTN=1

  """

  use GenServer

  require Logger

  alias Chat.Db

  def sync(nil), do: :nothing

  def sync(device) do
    device
    |> mount()
    |> tap(fn path ->
      path
      |> find_or_create_db()
      |> dump_my_data()
      |> get_new_data()
      |> stop_db()
    end)
    |> unmount()
  end

  def find_or_create_db(device_root) do
    path = Path.join([device_root, "bdb", Db.version_path()])
    File.mkdir_p!(path)
    {:ok, pid} = CubDB.start_link(path)

    pid
  end

  defp dump_my_data(other_db) do
    blink_write()
    Db.copy_data(Db.db(), other_db)
    blink_done()

    other_db
  end

  defp get_new_data(other_db) do
    blink_read()
    Db.copy_data(other_db, Db.db())
    blink_done()

    other_db
  end

  defp stop_db(other_db) do
    other_db
    |> CubDB.stop()
  end

  defp mount(device) do
    path = Path.join(["/root", "media", device])
    File.mkdir_p!(path)
    {_, 0} = System.cmd("mount", ["/dev/#{device}", path])

    path
  end

  defp unmount(path) do
    {_, 0} = System.cmd("umount", [path])

    :ok
  end

  def filter_state(state) do
    state
    |> get_in([:state, "subsystems", "block"])
    |> Enum.filter(fn
      [:state, "devices", "platform", "scb" | _rest] -> true
      _ -> false
    end)
    |> Enum.map(&Enum.drop(&1, 16))
    |> Enum.reject(fn x -> x == [] end)
    |> Enum.group_by(&List.first(&1))
  end

  def subscribe do
    SystemRegistry.register(min_interval: 1500)
  end

  def start_link(opts) do
    GenServer.start_link(__MODULE__, :ok, Keyword.merge([name: __MODULE__], opts))
  end

  @impl true
  def init(_) do
    subscribe()

    SystemRegistry.match(:_)
    |> filter_state()
    |> ok()
  end

  @impl true
  def handle_info({:system_registry, :global, devices}, connected_devices) do
    devices
    |> filter_state()
    |> tap(fn updated_devices ->
      updated_devices
      |> Map.keys()
      |> MapSet.new()
      |> MapSet.difference(connected_devices |> Map.keys() |> MapSet.new())
      |> MapSet.to_list()
      |> Enum.each(fn key ->
        updated_devices[key]
        |> List.flatten()
        |> Enum.reject(&(&1 == key))
        |> case do
          [] -> key
          list -> list |> Enum.sort() |> List.first()
        end
        |> tap(&Logger.info("New block device found: #{&1}"))
        |> sync()
      end)
    end)
    |> noreply()
  end

  def blink_done, do: Nerves.Leds.set("led1", true)
  def blink_read, do: Nerves.Leds.set("led1", :slowblink)
  def blink_write, do: Nerves.Leds.set("led1", :fastblink)

  defp ok(x), do: {:ok, x}
  defp noreply(x), do: {:noreply, x}
end
