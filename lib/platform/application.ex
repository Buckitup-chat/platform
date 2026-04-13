defmodule Platform.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    inject_on_start()

    children =
      [
        # Children for all targets
        # Starts a worker by calling: Platform.Worker.start_link(arg)
        # {Platform.Worker, arg},
      ] ++ common_children() ++ target_children()

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Platform.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # List all child processes to be supervised
  if Mix.target() == :host do
    defp target_children() do
      [
        # Children that only run on the host during development or test.
        # In general, prefer using `config/host.exs` for differences.
        #
        # Starts a worker by calling: Host.Worker.start_link(arg)
        # {Host.Worker, arg},
      ]
      |> more_target_children()
    end
  else
    defp target_children() do
      [
        # Children for all targets except host
        # Starts a worker by calling: Target.Worker.start_link(arg)
        # {Target.Worker, arg},
      ]
      |> more_target_children()
    end
  end

  #########################################################################

  if Mix.target() == :host do
    defp inject_on_start do
      :ok
    end
  else
    defp inject_on_start do
      mount_shared_memory()
    end
  end

  defp mount_shared_memory do
    File.mkdir_p!("/dev/shm")
    System.cmd("mount", ["-t", "tmpfs", "-o", "size=16M", "tmpfs", "/dev/shm"])
  end

  defp common_children do
    [
      {Task.Supervisor, name: Platform.TaskSupervisor}
    ]
  end

  if Mix.target() == :host do
    defp more_target_children(kids) do
      kids ++
        [
          Platform.Emulator.Drive.DriveIndication,
          Platform.App.DeviceSupervisor
        ]
    end
  else
    defp more_target_children(kids) do
      Chat.Time.init_time()

      pg_run_dir = "/tmp/pg_run"
      File.mkdir_p!(pg_run_dir)
      Platform.Tools.Postgres.make_accessible(pg_run_dir)

      kids ++
        [
          Platform.ChatBridge.Worker,
          {Platform.Dns.Server, 53},
          {Task,
           fn ->
             # Ensure wpa_supplicant control directory exists with proper permissions
             wpa_control_dir = "/tmp/vintage_net/wpa_supplicant"
             File.mkdir_p!(wpa_control_dir)
             File.chmod!(wpa_control_dir, 0o755)

             [
               "vm.dirty_expire_centisecs=300",
               "vm.dirty_writeback_centisecs=50",
               "vm.dirtytime_expire_seconds=500",
               "net.ipv4.ip_forward=1"
             ]
             |> Enum.each(&System.cmd("sysctl", ["-w", &1]))

             wan = "eth0"
             wifi = "wlan0"

             System.cmd("iptables", [
               "-t",
               "nat",
               "-A",
               "POSTROUTING",
               "-o",
               wan,
               "-j",
               "MASQUERADE"
             ])

             System.cmd("iptables", [
               "--append",
               "FORWARD",
               "--in-interface",
               wifi,
               "-j",
               "ACCEPT"
             ])

             System.cmd("iptables", [
               "-A",
               "INPUT",
               "-i",
               wan,
               "-m",
               "state",
               "--state",
               "RELATED,ESTABLISHED",
               "-j",
               "ACCEPT"
             ])

             {nat_out, _} = System.cmd("iptables", ["-t", "nat", "-S"])
             {filter_out, _} = System.cmd("iptables", ["-S"])
             Logger.info("[iptables] NAT rules:\n#{nat_out}")
             Logger.info("[iptables] FILTER rules:\n#{filter_out}")

             :inet_db.add_host({127, 0, 0, 1}, [~c"localhost", ~c"buckitup.app"])

             Logger.put_module_level(Tesla.Middleware.Logger, :error)

             System.cmd("modprobe", ["pwm-raspberrypi-poe"])

             try do
               mount_path = Application.get_env(:platform, :mount_path_media)
               File.mkdir_p!(mount_path)
               File.chmod!(mount_path, 0o755)
             catch
               t, e ->
                 require Logger
                 Logger.error(" [platform] error setting media: #{inspect(t)} #{inspect(e)}")
             end
           end},
          Platform.Network.IptablesMonitor,
          Chat.TimeKeeper,
          Platform.Storage.DriveIndication,
          Platform.App.DeviceSupervisor,
          Platform.App.DatabaseSupervisor,
          Platform.App.ZeroTierSupervisor
        ]
    end
  end
end
