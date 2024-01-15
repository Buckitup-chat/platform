defmodule Platform.App.ZeroTierSupervisor do
  @moduledoc "ZeroTier supervisor"

  use Supervisor

  def start_link(_arg) do
    Supervisor.start_link(__MODULE__, name: __MODULE__)
  end

  def init(_arg) do
    # cmd "zerotier-cli -D/root/zt info"
    [
      {Task,
       fn ->
         System.cmd("modprobe", ["tun"])
         System.cmd("zerotier-one", ["-d", "/root/zt"])
       end},
      Platform.ChatBridge.ZeroTierWorker
    ]
    |> Supervisor.init(strategy: :one_for_one)
  end
end
