defmodule Platform.Storage.Bouncer do
  @moduledoc """
  Prevents DBs from being renamed and used as other DB types.
  """

  use GenServer
  use OriginLog

  alias Chat.Db.DbType

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, [])
  end

  @impl true
  def init([db: db, type: type] = opts) do
    log("starting with opts #{inspect(opts)}", :info)

    expected_type = determine_type(type)

    case DbType.get(db) do
      nil ->
        log("No DB type found. Using #{type} as #{expected_type}", :info)
        DbType.put(db, expected_type)
        {:ok, nil}

      ^expected_type ->
        log("Using #{type} as #{expected_type}", :info)
        {:ok, nil}

      type ->
        log(
          "Wrong DB type! Got #{type} from DB, but expected #{expected_type}",
          :warning
        )

        {:error, nil}
    end
  end

  defp determine_type("backup_db"), do: "main_db"
  defp determine_type(type), do: type
end
