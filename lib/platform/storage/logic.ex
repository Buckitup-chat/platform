defmodule Platform.Storage.Logic do
  @moduledoc "Storage status: the Default unit and what flows between units"

  alias Chat.Db.Common
  alias Chat.Storage.Default
  alias Chat.Storage.Links

  def info do
    %{
      db: Default.unit().role,
      links: Links.list(),
      flags: Common.get_chat_db_env(:flags),
      writable: Common.get_chat_db_env(:writable),
      budget: Common.get_chat_db_env(:write_budget)
    }
  end
end
