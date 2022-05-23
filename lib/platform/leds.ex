defmodule Platform.Leds do
  @moduledoc "leds wrapper"

  def blink_done, do: Nerves.Leds.set("led1", true)
  def blink_read, do: Nerves.Leds.set("led1", :slowblink)
  def blink_write, do: Nerves.Leds.set("led1", :fastblink)
  def blink_dump, do: Nerves.Leds.set("led1", :slowwink)
end
