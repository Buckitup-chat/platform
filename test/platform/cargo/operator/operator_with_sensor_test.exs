defmodule Platform.Cargo.Sensor.OperatorWithSensorTest do
  @moduledoc """
  Operator with sensors enabled

  - Drive with cargo_room
  - Camera sensor and weight sensor configured
  - Cargo user enabled

  When drives comes
  - room synchronises
  - sensors polled into cargo_room
  - indication is correct
  """
  use ExUnit.Case

  @moduletag :capture_log
end
