defmodule Platform.Storage.BackupPlanTest do
  use ExUnit.Case, async: false

  import Support.Drive.Manipulation

  alias Chat.Admin.BackupSettings
  alias Chat.AdminRoom
  alias Chat.Storage.Default
  alias Chat.Storage.Links
  alias Chat.Storage.Unit
  alias Platform.Storage.BackupPlan

  @backup "sdk1"
  @main "sdl1"

  setup do
    await_supervision_started()
    settings = AdminRoom.get_backup_settings()

    on_exit(fn ->
      eject_all_drives()
      clean_filesystem()
      AdminRoom.store_backup_settings(settings)
    end)
  end

  test "one-shot backup syncs both ways and ejects, leaving no slot on internal" do
    AdminRoom.store_backup_settings(%BackupSettings{type: :regular})
    insert_backup_drive(@backup)

    # The drive ejects itself only from the plan's last step
    refute :timeout == await_till(fn -> nothing_is_started?() end, time: 20_000)
    assert :stopped == Links.status({:backup, :internal})
    assert :stopped == Links.status({:internal, :backup})
    assert [] == slots_on_internal()
  end

  test "continuous backup re-homes to main when main attaches" do
    AdminRoom.store_backup_settings(%BackupSettings{type: :continuous})
    insert_backup_drive(@backup)
    await_status({:internal, :backup}, :replicating)
    assert ["backup_from_internal"] == slots_on_internal()

    insert_main_drive(@main)
    refute :timeout == await_till(fn -> Default.unit().role == :main end, time: 20_000)

    await_status({:main, :backup}, :replicating)
    assert :stopped == Links.status({:internal, :backup})
    refute "backup_from_internal" in slots_on_internal()
  end

  test "plans follow the spec shape" do
    internal = Unit.internal()
    main = Unit.usb(@main, :main)
    backup = Unit.usb(@backup, :backup)

    assert [
             {:bootstrap, %{from: ^backup, to: ^internal}},
             {:bootstrap, %{from: ^internal, to: ^backup}},
             {:await, [%{from: ^backup}, %{to: ^backup}], :chunks},
             :eject
           ] = BackupPlan.plan(:backup_once, internal, backup)

    assert [_, _, _, {:replicate, %{from: ^internal, to: ^backup}}] =
             BackupPlan.plan(:backup_continuous, internal, backup)

    assert [
             {:stop, %{from: ^internal, to: ^backup}},
             {:bootstrap, %{from: ^main, to: ^backup}},
             {:replicate, %{from: ^main, to: ^backup}}
           ] = BackupPlan.plan(:backup_rehome, internal, main, backup)
  end

  defp await_status(link_id, status),
    do: refute(:timeout == await_till(fn -> Links.status(link_id) == status end, time: 20_000))

  # Slots links create on internal are named "<to>_from_internal"
  defp slots_on_internal do
    "SELECT slot_name FROM pg_replication_slots WHERE slot_name LIKE '%_from_internal'"
    |> Chat.Repo.query!()
    |> Map.fetch!(:rows)
    |> List.flatten()
  end
end
