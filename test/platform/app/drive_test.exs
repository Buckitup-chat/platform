defmodule Platform.App.DrivesTest do
  use ExUnit.Case

  import Support.Admin.Settings
  import Support.Drive.Manipulation

  test "main creation on empty drives" do
    prepare()
    media_settings_set_to(main: true, scenario: :backup)

    insert_empty_drive("drive1")
    assert only_main_scenario_started?()

    insert_empty_drive("drive2")
    assert main_and_non_main_scenario_started?()

    cleanup()
  end

  test "no main creation on empty drive" do
    prepare()
    media_settings_set_to(main: false, scenario: :backup)

    insert_empty_drive("drive1")
    assert only_backup_scenario_started?()

    cleanup()
  end

  test "no main creation if main started and main drive added" do
    prepare()
    media_settings_set_to(main: true, scenario: :backup)

    insert_main_drive("main_drive")
    assert only_main_scenario_started?()

    insert_main_drive("main_drive2")
    assert only_main_scenario_started?()

    cleanup()
  end

  test "no main creation if main started and new flash added" do
    prepare()
    media_settings_set_to(main: true, scenario: :backup)

    insert_main_drive("main_drive")
    assert only_main_scenario_started?()

    insert_empty_drive("drive2")
    assert main_and_non_main_scenario_started?()

    cleanup()
  end

  test "main + cargo, when main enabled" do
    prepare()
    media_settings_set_to(main: true, scenario: :backup)

    insert_main_drive("main_drive")
    assert only_main_scenario_started?()

    insert_cargo_drive("cargo_drive")
    assert main_and_cargo_scenario_started?()

    cleanup()
  end

  test "cargo starts cargo" do
    prepare()

    insert_cargo_drive("cargo_drive")
    assert only_cargo_scenario_started?()

    cleanup()
  end

  test "onliners starts correctly" do
    prepare()
    media_settings_set_to(main: false, scenario: :onliners)

    insert_onliners_drive("onliners_drive")
    assert only_onliners_scenario_started?()

    cleanup()
  end

  test "main + onliners" do
    prepare()
    media_settings_set_to(main: true, scenario: :backup)

    insert_empty_drive("drive1")
    assert only_main_scenario_started?()

    insert_onliners_drive("onliners_drive")
    assert main_and_onliners_scenario_started?()

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
end
