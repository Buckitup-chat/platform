defmodule Platform.Tools.Postgres.LifecycleTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Platform.Tools.Postgres.Lifecycle

  @moduletag :capture_log

  @timeout_ms 100

  describe "run_pg/3" do
    test "returns the tool exit status when it finishes in time" do
      assert {_output, 0} = Lifecycle.run_pg("sleep", ["0"], timeout: :timer.seconds(5))
    end

    test "gives up with a :timeout status instead of blocking forever" do
      assert {_output, :timeout} = sleep_outliving_timeout()
    end

    test "logs the timeout so a wedged tool is visible in db_log" do
      log = capture_log(fn -> sleep_outliving_timeout() end)

      assert log =~ "[error]"
      assert log =~ "sleep timed out after #{@timeout_ms}ms"
    end
  end

  defp sleep_outliving_timeout,
    do: Lifecycle.run_pg("sleep", ["30"], timeout: @timeout_ms)
end
