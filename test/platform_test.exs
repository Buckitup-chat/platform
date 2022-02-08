defmodule PlatformTest do
  use ExUnit.Case
  doctest Platform

  test "greets the world" do
    assert Platform.hello() == :world
  end
end
