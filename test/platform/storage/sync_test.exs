defmodule Platform.Storage.SyncTest do
  use ExUnit.Case, async: true

  alias Platform.Storage.Sync

  test "status transitions active -> done" do
    assert %{state: _} = Sync.status()

    :ok = Sync.set_active()
    assert %{state: :active} = Sync.status()

    :ok = Sync.set_done()
    assert %{state: :done} = Sync.status()
  end

  test "status transitions to error" do
    :ok = Sync.set_error("test error")
    assert %{state: {:error, "test error"}} = Sync.status()
  end

  test "schemas/1 returns all Electric-synced schemas" do
    schemas = Sync.schemas()
    assert is_list(schemas)
    assert Chat.Data.Schemas.UserCard in schemas
    assert Chat.Data.Schemas.FileChunk in schemas
    assert Chat.Data.Schemas.DialogMessage in schemas
    assert schemas == Chat.Data.Shapes.sync_schemas()
  end
end
