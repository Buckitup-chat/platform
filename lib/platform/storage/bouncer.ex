defmodule Platform.Storage.Bouncer do
  @moduledoc """
  Prevents DBs from being renamed and used as other DB types.
  """

  use GenServer
  use Toolbox.OriginLog

  alias Chat.Db.DbType
  alias Chat.Storage.Role

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, [])
  end

  @impl true
  def init([db: db, role: role] = opts) do
    log("starting with opts #{inspect(opts)}", :info)

    type = Role.dir(role)
    expected_type = expected_type(role)

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

  # A backup drive holds a copy of main, so it is stamped with main's type
  defp expected_type(:backup), do: Role.dir(:main)
  defp expected_type(role), do: Role.dir(role)
end
