defmodule Platform.ChatBridge.FirmwareDownloader do
  @moduledoc "Downloads firmware from URL with progress reporting"

  use Toolbox.OriginLog

  alias Phoenix.PubSub

  @firmware_source_path "/data/platform.fw"
  @outgoing_topic Application.compile_env!(:chat, :topic_from_platform)

  def download(url) do
    file = File.open!(@firmware_source_path, [:write, :binary])
    Process.put(:dl_bytes, 0)
    Process.put(:last_percent, -1)

    try do
      Req.get!(url,
        headers: [{"user-agent", "BuckitUp-Platform"}],
        into: fn {:data, chunk}, {req, resp} ->
          total = content_length(resp)
          received = Process.get(:dl_bytes, 0) + byte_size(chunk)
          Process.put(:dl_bytes, received)
          IO.binwrite(file, chunk)

          if total > 0 do
            percent = div(received * 100, total)
            maybe_broadcast_progress(percent)
          end

          {:cont, {req, resp}}
        end
      )

      {:ok, @firmware_source_path}
    rescue
      e ->
        log("firmware download failed: #{inspect(e)}", :debug)
        {:error, :download_failed}
    after
      File.close(file)
    end
  end

  def firmware_path, do: @firmware_source_path

  defp content_length(%{headers: headers}) do
    headers
    |> Enum.find_value(0, fn
      {"content-length", value} -> String.to_integer(value)
      _ -> false
    end)
  end

  defp maybe_broadcast_progress(percent) do
    last = Process.get(:last_percent, -1)

    if percent > last do
      Process.put(:last_percent, percent)
      broadcast_progress(percent)
    end
  end

  defp broadcast_progress(percent) do
    message = {:platform_response, {:github_firmware_upgrade, {:download_progress, percent}}}
    PubSub.broadcast(Chat.PubSub, @outgoing_topic, message)
  end
end
