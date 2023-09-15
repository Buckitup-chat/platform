defmodule Platform.Storage.Bouncer do
  @moduledoc """
  Prevents DBs from being renamed and used as other DB types.
  """

  use GenServer

  require Logger

  alias Chat.Db.DbType

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, [])
  end

  @impl true
  def init([db: db, type: type] = opts) do
    Logger.info("starting #{__MODULE__} with opts #{inspect(opts)}")

    expected_type = determine_type(type)

    case DbType.get(db) do
      nil ->
        Logger.info("[Bouncer] No DB type found. Using #{type} as #{expected_type}")
        DbType.put(db, expected_type)
        {:ok, nil}

      ^expected_type ->
        Logger.info("[Bouncer] Using #{type} as #{expected_type}")
        {:ok, nil}

      type ->
        Logger.warning("[Bouncer] Wrong DB type! Got #{type} from DB, but expected #{expected_type}")
        {:error, nil}
    end
  end

  defp determine_type("backup_db"), do: "main_db"
  defp determine_type(type), do: type
end
