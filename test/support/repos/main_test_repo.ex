defmodule Platform.Test.MainRepo do
  @moduledoc """
  Test repository simulating the main PostgreSQL database.

  Used in integration tests to verify sync behavior between internal and main databases.
  """

  use Ecto.Repo,
    otp_app: :platform,
    adapter: Ecto.Adapters.Postgres
end
