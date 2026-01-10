defmodule Platform.Tools.OsPidTest do
  use ExUnit.Case, async: false

  alias Platform.Tools.OsPid

  describe "alive?/1" do
    test "returns true for current Erlang VM process" do
      os_pid = System.pid() |> String.to_integer()
      assert OsPid.alive?(os_pid)
    end

    test "returns false for non-existent PID" do
      refute OsPid.alive?(999_999_999)
    end

    test "returns true for a spawned process and false after termination" do
      port = Port.open({:spawn_executable, "/bin/sleep"}, [:binary, args: ["30"]])
      {:os_pid, os_pid} = Port.info(port, :os_pid)

      assert is_integer(os_pid)
      assert os_pid > 0
      assert OsPid.alive?(os_pid)

      OsPid.kill(os_pid, 9)
      Process.sleep(200)

      refute OsPid.alive?(os_pid)
    end

    test "returns false after process is killed with SIGTERM" do
      port = Port.open({:spawn_executable, "/bin/sleep"}, [:binary, args: ["30"]])
      {:os_pid, os_pid} = Port.info(port, :os_pid)

      assert OsPid.alive?(os_pid)

      OsPid.kill(os_pid, "TERM")
      Process.sleep(200)

      refute OsPid.alive?(os_pid)
    end

    test "handles large non-existent PIDs" do
      refute OsPid.alive?(2_147_483_647)
    end

    test "handles negative PIDs" do
      refute OsPid.alive?(-1)
    end

    test "handles zero PID" do
      refute OsPid.alive?(0)
    end

    test "handles non-integer values" do
      refute OsPid.alive?(nil)
      refute OsPid.alive?("123")
    end
  end
end
