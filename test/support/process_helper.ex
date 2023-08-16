defmodule ProcessHelper do
  @moduledoc "Process helper"

  def process_not_running(
        process,
        timeout \\ 10_000,
        start \\ System.monotonic_time(:millisecond)
      ) do
    pid = Process.whereis(process)

    cond do
      is_nil(pid) ->
        true

      System.monotonic_time(:millisecond) - start >= timeout ->
        false

      true ->
        Process.sleep(100)
        process_not_running(process, timeout, start)
    end
  end
end
