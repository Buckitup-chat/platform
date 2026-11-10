defmodule Platform.Test.User do
  @moduledoc """
  Test-only schema over the legacy `users` table (`pub_key` PK + `name`).

  Chat's `Chat.Data.Schemas.User` was removed, but the table is still migrated, which
  makes it the smallest real table for sync tests.
  """

  use Ecto.Schema

  @primary_key {:pub_key, :binary, autogenerate: false}
  schema "users" do
    field(:name, :string)
  end
end
