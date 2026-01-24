defmodule Platform.Log do
  @moduledoc "Helpers for unified logging"

  use Toolbox.OriginLog

  def fsck_warn(code, msg) do
    log(["[fsck] ", "(", inspect(code), ") ", msg], :warning)
  end

  def postgres_log(msg, level \\ :info) do
    log(["[postgres] ", msg], level)
  end
end
