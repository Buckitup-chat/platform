defmodule PlatformTest.LanChatBridgeTest do
  use ExUnit.Case, async: true
  import Rewire

  alias Platform.ChatBridge.Lan

  defmodule IpLanMock do
    def getifaddrs,
      do:
        {:ok,
         [
           {~c"lo0",
            [
              flags: [:up, :loopback, :running, :multicast],
              addr: {127, 0, 0, 1},
              netmask: {255, 0, 0, 0},
              addr: {0, 0, 0, 0, 0, 0, 0, 1},
              netmask: {65535, 65535, 65535, 65535, 65535, 65535, 65535, 65535},
              addr: {65152, 0, 0, 0, 0, 0, 0, 1},
              netmask: {65535, 65535, 65535, 65535, 0, 0, 0, 0}
            ]},
           {~c"eth0",
            [
              flags: [:up, :broadcast, :running, :multicast],
              addr: {65152, 0, 0, 0, 6377, 15172, 62596, 17500},
              netmask: {65535, 65535, 65535, 65535, 0, 0, 0, 0},
              addr: {192, 168, 0, 200},
              netmask: {255, 255, 255, 0},
              broadaddr: {192, 168, 0, 255},
              hwaddr: [240, 24, 152, 134, 174, 193]
            ]}
         ]}
  end

  rewire(Lan, [{:inet, IpLanMock}])

  test "correct ip and mask" do
    %{}
    |> get_ip_address()
    |> assert_correct_ip()
    |> get_ip_mask()
    |> assert_correct_mask()
  end

  defp get_ip_address(context) do
    context
    |> Map.put(:ip, Lan.get_ip_address())
  end

  defp get_ip_mask(context) do
    context
    |> Map.put(:mask, Lan.get_ip_mask())
  end

  defp assert_correct_ip(context) do
    assert context.ip == "192.168.0.200"
    context
  end

  defp assert_correct_mask(context) do
    assert context.mask == "255.255.255.0"
    context
  end
end
