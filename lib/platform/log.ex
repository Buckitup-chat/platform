defmodule Platform.Log do
  @moduledoc "Helpers for unified logging"

  require Logger

  def fsck_warn(code, msg) do
    log(["[fsck] ", "(", inspect(code), ") ", msg], :warn)
  end

  defp log(msg, level) do
    Logger.log(level, ["[platform] " | msg])
  end
end
