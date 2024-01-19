defmodule PlatformTest.Lan.ZeroTierWorkerTest do
  use ExUnit.Case, async: true
  import Rewire
  import ChatSupport.Utils, only: [await_till: 2]

  alias Platform.ChatBridge.ZeroTierWorker

  defmodule PubSubMock do
    def subscribe(_, _), do: :ok
  end

  rewire(ZeroTierWorker, [
    {Phoenix.PubSub, PubSubMock},
    {System, PlatformTest.Mocks.CharBridge.SystemMockForZeroTierWorkerTest}
  ])

  setup do
    {:ok, worker_pid} = start_supervised({ZeroTierWorker, [name: __MODULE__.Worker]})

    {:ok, agent_pid} =
      start_supervised(%{
        id: :agent,
        start: {Agent, :start_link, [fn -> MapSet.new() end, [name: __MODULE__.Agent]]}
      })

    %{pid: worker_pid, agent_pid: agent_pid}
    |> assert_worker_and_agent_started
  end

  test "zerotier should work correctly", context do
    context
    |> request_info
    |> assert_info_requested
    |> assert_info_response_received
    |> clear_messages
    |> request_list_networks
    |> assert_list_networks_requested
    |> assert_list_networks_response_received
    |> clear_messages
    |> request_join_network
    |> assert_join_network_requested
    |> assert_join_network_response_received
    |> clear_messages
    |> request_leave_network
    |> assert_leave_network_requested
    |> clear_messages
    |> request_unknown_command
    |> assert_unknown_command_response_received
  end

  defp request_info(context) do
    send(context.pid, {:info, self()})
    context
  end

  defp request_list_networks(context) do
    send(context.pid, {:list_networks, self()})
    context
  end

  defp request_join_network(context) do
    send(context.pid, {{:join_network, "1"}, self()})
    context
  end

  defp request_leave_network(context) do
    send(context.pid, {{:leave_network, "1"}, self()})
    context
  end

  defp request_unknown_command(context) do
    send(context.pid, {:unknown_command, self()})
    context
  end

  defp assert_worker_and_agent_started(context) do
    assert Process.alive?(context.pid)
    assert Process.alive?(context.agent_pid)
    context
  end

  defp assert_info_requested(context) do
    "zerotier-cli -D/root/zt -j info" |> assert_cmd_requested(context.agent_pid)
    context
  end

  defp assert_list_networks_requested(context) do
    "zerotier-cli -D/root/zt -j listnetworks" |> assert_cmd_requested(context.agent_pid)
    context
  end

  defp assert_join_network_requested(context) do
    "zerotier-cli -D/root/zt -j join 1" |> assert_cmd_requested(context.agent_pid)
    context
  end

  defp assert_leave_network_requested(context) do
    "zerotier-cli -D/root/zt -j leave 1" |> assert_cmd_requested(context.agent_pid)
    context
  end

  defp assert_info_response_received(context) do
    assert_receive({:info, {:ok, _}})
    context
  end

  defp assert_list_networks_response_received(context) do
    assert_receive({:list_networks, {:ok, _}})
    context
  end

  defp assert_join_network_response_received(context) do
    assert_receive({{:join_network, "1"}, {:ok, _}})
    context
  end

  defp assert_unknown_command_response_received(context) do
    assert_receive({:unknown_command, {:error, _}})
    context
  end

  defp assert_cmd_requested(cmd, agent_pid) do
    refute :timeout ==
             await_till(fn -> Agent.get(agent_pid, &MapSet.member?(&1, cmd)) end,
               step: 50,
               timeout: 500
             )
  end

  defp clear_messages(context) do
    flush_messages()
    context
  end

  defp flush_messages() do
    receive do
      _ -> flush_messages()
    after
      0 -> :ok
    end
  end
end
