defmodule Platform.App.DrivesTest do
  use ExUnit.Case

  import ExUnit.CaptureLog

  require Logger
  import Support.Admin.Settings
  import Support.Drive.Manipulation

  alias Chat.Sync.UsbDriveDumpRoom

  test "main creation on empty drives" do
    prepare()
    media_settings_set_to(main: true, scenario: :backup)

    insert_empty_drive("sdb1")
    assert only_main_scenario_started?()
    assert pg_started?("sdb1")

    insert_backup_drive("sdd1")
    assert main_and_non_main_scenario_started?()
    assert pg_started?("sdd1")

    cleanup()
  end

  test "blank drive with optimize enabled is formatted, then gets its role dir" do
    prepare()
    media_settings_set_to(main: false, scenario: :cargo)
    media_optimize_set_to(true)
    # test_helper.exs keeps :platform at :error
    traced = [Platform.Emulator.Drive.FsOptimizer, Platform.UsbDrives.Resolver]
    Enum.each(traced, &Logger.put_module_level(&1, :info))

    on_exit(fn ->
      media_optimize_set_to(false)
      Enum.each(traced, &Logger.put_module_level(&1, :error))
    end)

    {_, log} = with_log(fn -> insert_empty_drive("sdg1") end)
    assert only_cargo_scenario_started?()
    assert File.dir?(drive_path("sdg1") |> Path.join("cargo_db"))

    [formatted, resolved] =
      ["F2FS optimization emulated for", "sdg1 resolved as {:role, :cargo}"]
      |> Enum.map(fn line -> log |> :binary.match(line) |> elem(0) end)

    assert formatted < resolved

    cleanup()
  end

  test "no main creation on empty drive" do
    prepare()
    media_settings_set_to(main: false, scenario: :backup)

    insert_empty_drive("sdb1")
    assert only_backup_scenario_started?()

    cleanup()
  end

  test "no main creation if main started and main drive added" do
    prepare()
    media_settings_set_to(main: true, scenario: :backup)

    insert_main_drive("sde1")
    assert only_main_scenario_started?()

    insert_main_drive("sdf1")
    assert await_resolved("sdf1")
    assert only_main_scenario_started?()
    refute pg_started?("sdf1")

    cleanup()
  end

  test "no main creation if main started and new flash added" do
    prepare()
    media_settings_set_to(main: true, scenario: :backup)

    insert_main_drive("sde1")
    assert only_main_scenario_started?()

    insert_empty_drive("sdc1")
    assert main_and_backup_scenario_started?()

    cleanup()
  end

  test "main + cargo, when main enabled" do
    prepare()
    media_settings_set_to(main: true, scenario: :backup)

    insert_main_drive("sde1")
    assert only_main_scenario_started?()

    insert_cargo_drive("sdg1")
    assert main_and_cargo_scenario_started?()

    cleanup()
  end

  test "cargo starts cargo" do
    prepare()

    insert_cargo_drive("sdg1")
    assert only_cargo_scenario_started?()
    refute pg_started?("sdg1")

    cleanup()
  end

  test "onliners starts correctly" do
    prepare()
    media_settings_set_to(main: false, scenario: :onliners)

    insert_onliners_drive("sdh1")
    assert only_onliners_scenario_started?()
    refute pg_started?("sdh1")

    cleanup()
  end

  test "main + onliners" do
    prepare()
    media_settings_set_to(main: true, scenario: :backup)

    insert_empty_drive("sdb1")
    assert only_main_scenario_started?()

    insert_onliners_drive("sdh1")
    assert main_and_onliners_scenario_started?()

    cleanup()
  end

  test "usb data dump w/ room set" do
    prepare()

    create_room_and_set_it_to_receive_dump()
    insert_dump_drive("sdi1")
    assert only_dump_scenario_started?()
    refute pg_started?("sdi1")
    refute File.exists?(drive_path("sdi1") |> Path.join("backup_db"))

    cleanup()
  end

  test "usb data dump w/o room set" do
    prepare()
    media_settings_set_to(main: false, scenario: :backup)

    insert_dump_drive("sdi1")
    assert only_backup_scenario_started?()

    cleanup()
  end

  defp prepare do
    await_supervision_started()
    assert nothing_is_started?()
  end

  defp cleanup do
    eject_all_drives()
    clean_filesystem()
  end

  defp create_room_and_set_it_to_receive_dump do
    operator = Chat.User.login("Operator")
    Chat.User.register(operator)

    {room_identity, _room} = Chat.Rooms.add(operator, "Room", :public)
    room_key = room_identity |> Chat.Identity.pub_key()

    room_key
    |> Base.encode16(case: :lower)

    Chat.Rooms.add(operator, "Other room", :public)

    monotonic_offset =
      DateTime.utc_now()
      |> DateTime.to_unix()
      |> Chat.Time.monotonic_offset()

    UsbDriveDumpRoom.activate(room_key, room_identity, monotonic_offset)
  end
end
