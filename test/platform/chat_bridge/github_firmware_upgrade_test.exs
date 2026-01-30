defmodule PlatformTest.ChatBridge.GithubFirmwareUpgradeTest do
  use ExUnit.Case, async: true

  import Rewire

  alias Platform.ChatBridge.FirmwareDownloader
  alias Phoenix.PubSub

  @outgoing_topic Application.compile_env!(:chat, :topic_from_platform)
  @firmware_url "https://github.com/Buckitup-chat/platform/releases/download/v0.4.1/platform.fw"

  describe "FirmwareDownloader" do
    defmodule ReqSuccessMock do
      def get!(url, opts) do
        into_fn = Keyword.get(opts, :into)

        resp = %Req.Response{
          status: 200,
          headers: [{"content-length", "1000"}]
        }

        chunks = [
          String.duplicate("a", 250),
          String.duplicate("b", 250),
          String.duplicate("c", 250),
          String.duplicate("d", 250)
        ]

        Enum.reduce(chunks, {%Req.Request{url: URI.parse(url)}, resp}, fn chunk, acc ->
          {:cont, new_acc} = into_fn.({:data, chunk}, acc)
          new_acc
        end)
      end
    end

    defmodule ReqFailureMock do
      def get!(_url, _opts) do
        raise "Network error"
      end
    end

    defmodule FileMock do
      def open!(_path, _modes), do: :mock_file
      def close(:mock_file), do: :ok
    end

    defmodule IOMock do
      def binwrite(:mock_file, _data), do: :ok
    end

    rewire(FirmwareDownloader, Req: ReqSuccessMock, File: FileMock, IO: IOMock,
      as: SuccessDownloader
    )

    rewire(FirmwareDownloader, Req: ReqFailureMock, File: FileMock, IO: IOMock,
      as: FailureDownloader
    )

    test "successful download returns path" do
      assert {:ok, "/data/platform.fw"} = SuccessDownloader.download(@firmware_url)
    end

    test "broadcasts download progress" do
      PubSub.subscribe(Chat.PubSub, @outgoing_topic)

      {:ok, _path} = SuccessDownloader.download(@firmware_url)

      assert_receive {:platform_response, {:github_firmware_upgrade, {:download_progress, 25}}}
      assert_receive {:platform_response, {:github_firmware_upgrade, {:download_progress, 50}}}
      assert_receive {:platform_response, {:github_firmware_upgrade, {:download_progress, 75}}}
      assert_receive {:platform_response, {:github_firmware_upgrade, {:download_progress, 100}}}

      PubSub.unsubscribe(Chat.PubSub, @outgoing_topic)
    end

    test "returns error on download failure" do
      assert {:error, :download_failed} = FailureDownloader.download(@firmware_url)
    end

    test "firmware_path returns correct path" do
      assert FirmwareDownloader.firmware_path() == "/data/platform.fw"
    end
  end

  describe "Logic.upgrade_firmware_from_url/1" do
    alias Platform.ChatBridge.Logic

    defmodule DownloaderSuccessMock do
      def download(_url), do: {:ok, "/data/platform.fw"}
    end

    defmodule DownloaderFailureMock do
      def download(_url), do: {:error, :download_failed}
    end

    defmodule FwupSuccessMock do
      def upgrade_from_file(_path), do: :ok
    end

    defmodule FwupFailureMock do
      def upgrade_from_file(_path), do: {:error, :upgrade_failed}
    end

    rewire(Logic, [
      {Platform.ChatBridge.FirmwareDownloader, DownloaderSuccessMock},
      {Platform.Tools.Fwup, FwupSuccessMock}
    ])

    test "returns :done on successful download and upgrade" do
      assert {:github_firmware_upgrade, :done} = Logic.upgrade_firmware_from_url(@firmware_url)
    end
  end

  describe "Logic.upgrade_firmware_from_url/1 - download failure" do
    alias Platform.ChatBridge.Logic

    defmodule DownloaderFailureMock2 do
      def download(_url), do: {:error, :download_failed}
    end

    defmodule FwupSuccessMock2 do
      def upgrade_from_file(_path), do: :ok
    end

    rewire(Logic, [
      {Platform.ChatBridge.FirmwareDownloader, DownloaderFailureMock2},
      {Platform.Tools.Fwup, FwupSuccessMock2}
    ])

    test "returns error when download fails" do
      assert {:github_firmware_upgrade, {:error, :download_failed}} =
               Logic.upgrade_firmware_from_url(@firmware_url)
    end
  end

  describe "Logic.upgrade_firmware_from_url/1 - upgrade failure" do
    alias Platform.ChatBridge.Logic

    defmodule DownloaderSuccessMock2 do
      def download(_url), do: {:ok, "/data/platform.fw"}
    end

    defmodule FwupFailureMock2 do
      def upgrade_from_file(_path), do: {:error, :upgrade_failed}
    end

    rewire(Logic, [
      {Platform.ChatBridge.FirmwareDownloader, DownloaderSuccessMock2},
      {Platform.Tools.Fwup, FwupFailureMock2}
    ])

    test "returns error when upgrade fails" do
      assert {:github_firmware_upgrade, {:error, :upgrade_failed}} =
               Logic.upgrade_firmware_from_url(@firmware_url)
    end
  end
end
