defmodule Platform.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Platform.Supervisor]

    children =
      [
        # {Platform.Dns, 53}
        # Children for all targets
        # Starts a worker by calling: Platform.Worker.start_link(arg)
        # {Platform.Worker, arg},
        {Task.Supervisor, name: Platform.TaskSupervisor}
      ] ++ children(target())

    Supervisor.start_link(children, opts)
  end

  # List all child processes to be supervised
  def children(:host) do
    [
      # Children that only run on the host
      # Starts a worker by calling: Platform.Worker.start_link(arg)
      # {Platform.Worker, arg},
    ]
  end

  def children(_target) do
    [
      # Children for all targets except host
      # Starts a worker by calling: Platform.Worker.start_link(arg)
      # {Platform.Worker, arg},
      Platform.App.DeviceSupervisor,
      Platform.ChatBridge.Worker,
      {Task,
       fn ->
         [
           "vm.dirty_expire_centisecs=300",
           "vm.dirty_writeback_centisecs=50",
           "vm.dirtytime_expire_seconds=500",
           "net.ipv4.forwarding=1"
         ]
         |> Enum.each(&System.cmd("sysctl", ["-w", &1]))

         Logger.put_module_level(Tesla.Middleware.Logger, :error)
       end},
      Platform.DriveDetector
    ]
  end

  def target do
    Application.get_env(:platform, :target)
  end
end
