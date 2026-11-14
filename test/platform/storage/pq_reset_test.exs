defmodule Platform.Storage.PqResetTest do
  use ExUnit.Case, async: false

  alias Chat.Storage.Role
  alias Chat.Storage.Unit
  alias Platform.Storage.PqReset

  @moduletag :capture_log
  @device "sdq1"

  setup do
    mount = Unit.root(@device)
    File.rm_rf!(mount)
    on_exit(fn -> File.rm_rf!(mount) end)

    %{mount: mount}
  end

  describe "usb/1" do
    test "moves the legacy cluster and blobs under the role dir, keeps CubDB", %{mount: mount} do
      main = Unit.usb(@device, :main)

      touch(Path.join(mount, "pg/data/PG_VERSION"))
      touch(Path.join([Unit.path(main, :cub_files), "pq_files", "ab/f_ab/0"]))
      touch(Path.join(Unit.path(main, :cub_db), "0.cub"))
      touch(Path.join(Unit.path(main, :cub_files), "aa/key"))

      assert PqReset.usb(@device) |> Enum.sort() ==
               [
                 {:moved, Path.join(mount, "pg"), Unit.path(main, :pg)},
                 {:moved, Path.join(Unit.path(main, :cub_files), "pq_files"),
                  Unit.path(main, :pq_files)}
               ]
               |> Enum.sort()

      refute File.exists?(Path.join(mount, "pg"))
      refute File.exists?(Path.join(Unit.path(main, :cub_files), "pq_files"))

      assert File.read!(Path.join(Unit.path(main, :pg), "data/PG_VERSION")) == "x"
      assert File.exists?(Path.join(Unit.path(main, :pq_files), "ab/f_ab/0"))
      assert File.exists?(Path.join(Unit.path(main, :cub_db), "0.cub"))
      assert File.exists?(Path.join(Unit.path(main, :cub_files), "aa/key"))
      assert Role.from_mount(mount) == {:ok, :main}
    end

    test "the cluster goes to the resolved role; blobs stay with their own role", %{mount: mount} do
      main = Unit.usb(@device, :main)
      backup = Unit.usb(@device, :backup)

      touch(Path.join(mount, "pg/data/PG_VERSION"))
      touch(Path.join([Unit.path(main, :cub_files), "pq_files", "ab/f_ab/0"]))
      touch(Path.join([Unit.path(backup, :cub_files), "pq_files", "cd/f_cd/0"]))

      PqReset.usb(@device)

      assert File.exists?(Path.join(Unit.path(backup, :pg), "data/PG_VERSION"))
      refute File.exists?(Unit.path(main, :pg))
      assert File.exists?(Path.join(Unit.path(main, :pq_files), "ab/f_ab/0"))
      assert File.exists?(Path.join(Unit.path(backup, :pq_files), "cd/f_cd/0"))
      assert Role.from_mount(mount) == {:ok, :backup}
    end

    test "removes what has no home: a role without PG", %{mount: mount} do
      cargo = Unit.usb(@device, :cargo)

      touch(Path.join(mount, "pg/data/PG_VERSION"))
      touch(Path.join([Unit.path(cargo, :cub_files), "pq_files", "ab/f_ab/0"]))
      touch(Path.join(Unit.path(cargo, :cub_db), "0.cub"))

      assert PqReset.usb(@device) |> Enum.sort() ==
               [
                 {:removed, Path.join(mount, "pg")},
                 {:removed, Path.join(Unit.path(cargo, :cub_files), "pq_files")}
               ]
               |> Enum.sort()

      assert File.ls!(Path.join(mount, Role.dir(:cargo))) |> Enum.sort() ==
               ["v.10.1", "v.10.1_files"]

      assert File.ls!(Unit.path(cargo, :cub_files)) == []
    end

    test "the unit's own copy wins over the legacy one", %{mount: mount} do
      main = Unit.usb(@device, :main)

      touch(Path.join(mount, "pg/data/PG_VERSION"))
      File.mkdir_p!(Unit.path(main, :cub_db))
      File.mkdir_p!(Path.join(Unit.path(main, :pg), "data"))
      File.write!(Path.join(Unit.path(main, :pg), "data/PG_VERSION"), "own")

      assert [{:removed, Path.join(mount, "pg")}] == PqReset.usb(@device)
      assert File.read!(Path.join(Unit.path(main, :pg), "data/PG_VERSION")) == "own"
    end

    test "is idempotent", %{mount: mount} do
      touch(Path.join(mount, "pg/data/PG_VERSION"))
      File.mkdir_p!(Unit.usb(@device, :main) |> Unit.path(:cub_db))

      assert [{:moved, _, _}] = PqReset.usb(@device)
      assert [] == PqReset.usb(@device)
    end

    test "a drive with only the legacy PG reads as blank afterwards", %{mount: mount} do
      touch(Path.join(mount, "pg/data/PG_VERSION"))

      assert [{:removed, _}] = PqReset.usb(@device)

      assert File.ls!(mount) == []
      assert Role.from_mount(mount) == :blank
    end
  end

  describe "internal/1" do
    setup do
      root =
        Path.join(System.tmp_dir!(), "pq_reset_internal_#{System.unique_integer([:positive])}")

      on_exit(fn -> File.rm_rf!(root) end)

      %{unit: %Unit{id: :internal, role: :internal, root: root}}
    end

    test "moves legacy PG, blobs and Electric cache under the role dir", %{unit: unit} do
      touch(Path.join(unit.root, "pg/data/PG_VERSION"))
      touch(Path.join([Unit.path(unit, :cub_files), "pq_files", "ab/f_ab/0"]))
      touch(Path.join(unit.root, "electric/shapes"))
      touch(Path.join(Unit.path(unit, :cub_db), "0.cub"))

      assert [{:moved, _, _}, {:moved, _, _}, {:moved, _, _}] = PqReset.internal(unit)
      assert [] == PqReset.internal(unit)

      refute File.exists?(Path.join(unit.root, "pg"))
      refute File.exists?(Path.join(unit.root, "electric"))
      assert File.exists?(Path.join(Unit.path(unit, :pg), "data/PG_VERSION"))
      assert File.exists?(Path.join(Unit.path(unit, :pq_files), "ab/f_ab/0"))
      assert File.exists?(Path.join(Unit.path(unit, :electric), "shapes"))
      assert File.exists?(Path.join(Unit.path(unit, :cub_db), "0.cub"))
    end

    test "the unit's own copies win", %{unit: unit} do
      touch(Path.join(unit.root, "pg/data/PG_VERSION"))
      touch(Path.join(Unit.path(unit, :pg), "data/PG_VERSION"))

      assert [{:removed, _}] = PqReset.internal(unit)
      assert File.exists?(Path.join(Unit.path(unit, :pg), "data/PG_VERSION"))
    end
  end

  defp touch(path) do
    path |> Path.dirname() |> File.mkdir_p!()
    File.write!(path, "x")
  end
end
