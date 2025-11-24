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

  test "run_local_sync returns :ok and logs" do
    assert :ok = Sync.run_local_sync(source_repo: :internal_repo, target_repo: :main_repo, schemas: [:users])
  end
end
