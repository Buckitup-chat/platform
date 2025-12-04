defmodule OriginLogTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  @moduletag :capture_log

  doctest OriginLog

  describe "generate_prefix/1" do
    test "converts simple module name to bracketed lowercase prefix" do
      assert "[_Platform_] " = OriginLog.generate_prefix(Platform)
    end

    test "converts nested module name to multiple brackets" do
      assert "[_Platform.Storage.Logic_] " = OriginLog.generate_prefix(Platform.Storage.Logic)
    end

    test "converts camelcase to underscore format" do
      assert "[_MyApp.HTTPClient_] " = OriginLog.generate_prefix(MyApp.HTTPClient)
    end

    test "handles deeply nested modules" do
      assert "[_A.B.C.D.E_] " = OriginLog.generate_prefix(A.B.C.D.E)
    end
  end

  describe "normalize_iolist/1" do
    test "returns binaries unchanged" do
      assert "message" == OriginLog.normalize_iolist("message")
    end

    test "inspects integers" do
      assert "42" == OriginLog.normalize_iolist(42)
    end

    test "recursively normalizes nested lists" do
      assert ["start", "99", "{:tuple, 1}"] ==
               OriginLog.normalize_iolist(["start", 99, {:tuple, 1}])
    end

    test "short charlists are converted to binaries" do
      assert "hi" == OriginLog.normalize_iolist('hi')
    end

    test "longer charlists are kept as lists" do
      assert 'long' == OriginLog.normalize_iolist('long')
    end
  end

  describe "use OriginLog" do
    defmodule X do
      use OriginLog

      def do_log(message, level), do: log(message, level)
    end

    test "injected log/2 function logs with correct prefix" do
      output = capture_log(fn -> X.do_log("test message", :info) end)

      assert output =~ "[_OriginLogTest.X_]"
      assert output =~ "test message"
    end

    test "injected log/2 supports different log levels" do
      output = capture_log(fn -> X.do_log("warning message", :warning) end)

      assert output =~ "warning message"
    end

    test "injected log/2 handles iolist messages" do
      output = capture_log(fn -> X.do_log(["part1", " ", "part2"], :info) end)

      assert output =~ "part1 part2"
    end

    test "injected log/2 inspects unsupported IO list segments" do
      output = capture_log(fn -> X.do_log(["value=", {:tuple, 1}, 256], :info) end)

      assert output =~ "value={:tuple, 1}256"
    end
  end
end
