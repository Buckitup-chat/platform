defmodule Platform.Storage.BouncerTest do
  use ExUnit.Case, async: false

  alias Platform.App.Db.MainDbSupervisor

  @storage_mount_path Application.compile_env(:platform, :mount_path_storage)
  @media_mount_path Application.compile_env(:platform, :mount_path_media)

  #  setup do
  #    start_supervised!(
  #      {DynamicSupervisor, name: Platform.MainDbSupervisor, strategy: :one_for_one}
  #    )
  #
  #    start_supervised!(
  #      {DynamicSupervisor, name: Platform.App.Media.DynamicSupervisor, strategy: :one_for_one}
  #    )
  #
  #    :ok
  #  end

  @tag :skip
  test "does not allow DB directory rename" do
    assert {:ok, _pid} =
             Platform.MainDbSupervisor
             |> DynamicSupervisor.start_child({MainDbSupervisor, [nil]})

    assert pid = Process.whereis(MainDbSupervisor)
    DynamicSupervisor.terminate_child(Platform.MainDbSupervisor, pid)
    assert ProcessHelper.process_not_running(MainDbSupervisor, 500)

    File.rename(
      Path.join(@storage_mount_path, "main_db"),
      Path.join(@media_mount_path, "backup_db")
    )

    assert {:ok, _pid} =
             Platform.App.Media.DynamicSupervisor
             |> DynamicSupervisor.start_child({Platform.App.Media.Supervisor, [nil]})

    assert pid = Process.whereis(Platform.App.Media.Supervisor)
    DynamicSupervisor.terminate_child(Platform.App.Media.DynamicSupervisor, pid)
    assert ProcessHelper.process_not_running(Platform.App.Media.Supervisor, 500)

    File.rename(
      Path.join(@media_mount_path, "backup_db"),
      Path.join(@media_mount_path, "onliners_db")
    )

    assert {:error, _reason} =
             Platform.App.Media.DynamicSupervisor
             |> DynamicSupervisor.start_child({Platform.App.Media.Supervisor, [nil]})

    assert ProcessHelper.process_not_running(Platform.App.Media.Supervisor, 500)

    path = Path.join(@media_mount_path, "onliners_db")
    File.rm_rf(path)
    File.mkdir_p(path)

    assert {:ok, _pid} =
             Platform.App.Media.DynamicSupervisor
             |> DynamicSupervisor.start_child({Platform.App.Media.Supervisor, [nil]})

    assert pid = Process.whereis(Platform.App.Media.Supervisor)
    DynamicSupervisor.terminate_child(Platform.App.Media.DynamicSupervisor, pid)
    assert ProcessHelper.process_not_running(Platform.App.Media.Supervisor, 500)

    File.rename(
      Path.join(@media_mount_path, "onliners_db"),
      Path.join(@media_mount_path, "cargo_db")
    )

    assert {:error, _reason} =
             Platform.App.Media.DynamicSupervisor
             |> DynamicSupervisor.start_child({Platform.App.Media.Supervisor, [nil]})

    assert ProcessHelper.process_not_running(Platform.App.Media.Supervisor, 500)

    path = Path.join(@media_mount_path, "cargo_db")
    File.rm_rf(path)
    File.mkdir_p(path)

    assert {:ok, _pid} =
             Platform.App.Media.DynamicSupervisor
             |> DynamicSupervisor.start_child({Platform.App.Media.Supervisor, [nil]})

    File.rename(
      Path.join(@media_mount_path, "cargo_db"),
      Path.join(@media_mount_path, "main_db")
    )

    assert {:error, _reason} =
             Platform.App.Media.DynamicSupervisor
             |> DynamicSupervisor.start_child({Platform.App.Media.Supervisor, [nil]})

    assert ProcessHelper.process_not_running(Platform.App.Media.Supervisor, 100)

    path = Path.join(@media_mount_path, "backup_db")
    File.rm_rf(path)
    File.mkdir_p(path)

    assert {:ok, _pid} =
             Platform.App.Media.DynamicSupervisor
             |> DynamicSupervisor.start_child({Platform.App.Media.Supervisor, [nil]})

    assert pid = Process.whereis(Platform.App.Media.Supervisor)
    DynamicSupervisor.terminate_child(Platform.App.Media.DynamicSupervisor, pid)
    assert ProcessHelper.process_not_running(Platform.App.Media.Supervisor, 500)

    File.rename(
      Path.join(@media_mount_path, "backup_db"),
      Path.join(@storage_mount_path, "main_db")
    )

    assert {:ok, _pid} =
             Platform.MainDbSupervisor
             |> DynamicSupervisor.start_child({MainDbSupervisor, [nil]})
  end
end
