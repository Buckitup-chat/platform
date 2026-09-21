defmodule Platform.DeviceIdTest do
  use ExUnit.Case, async: true

  alias Platform.DeviceId

  @rpi4_cpuinfo """
  Hardware\t: BCM2835
  Revision\t: d03114
  Serial\t\t: 100000001234abcd
  Model\t\t: Raspberry Pi 4 Model B Rev 1.4
  """

  @rpi5_cpuinfo """
  Serial\t\t: abcdef0123456789
  Model\t\t: Raspberry Pi 5 Model B Rev 1.0
  """

  describe "parse_field/2" do
    test "extracts Serial from RPi4 cpuinfo" do
      assert {:ok, "100000001234abcd"} = DeviceId.parse_field(@rpi4_cpuinfo, "Serial")
    end

    test "extracts Model from RPi4 cpuinfo" do
      assert {:ok, "Raspberry Pi 4 Model B Rev 1.4"} = DeviceId.parse_field(@rpi4_cpuinfo, "Model")
    end

    test "extracts Serial from RPi5 cpuinfo" do
      assert {:ok, "abcdef0123456789"} = DeviceId.parse_field(@rpi5_cpuinfo, "Serial")
    end

    test "returns error for missing field" do
      assert :error = DeviceId.parse_field("Hardware\t: BCM2835\n", "Serial")
    end
  end
end
