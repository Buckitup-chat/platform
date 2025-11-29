defmodule Platform.Test.InternalRepo do
  @moduledoc """
  Test repository simulating the internal PostgreSQL database.

  Used in integration tests to verify sync behavior between internal and main databases.
  """

  use Ecto.Repo,
    otp_app: :platform,
    adapter: Ecto.Adapters.Postgres
end
