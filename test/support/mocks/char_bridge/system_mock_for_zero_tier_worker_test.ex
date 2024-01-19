defmodule PlatformTest.Mocks.CharBridge.SystemMockForZeroTierWorkerTest do
  @moduledoc false
  def cmd(cmd, args) do
    full_cmd = [cmd | args] |> List.flatten() |> Enum.join(" ")

    Agent.update(
      PlatformTest.Lan.ZeroTierWorkerTest.Agent,
      &MapSet.put(&1, full_cmd)
    )

    if full_cmd == "zerotier-cli -D/root/zt -j " do
      {"empty cmd", 1}
    else
      {"", 0}
    end
  end

end
