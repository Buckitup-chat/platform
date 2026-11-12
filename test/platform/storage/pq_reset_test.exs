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
    test "drops the legacy PQ generation and keeps CubDB", %{mount: mount} do
      main = Unit.usb(@device, :main)
      backup = Unit.usb(@device, :backup)

      legacy = [
        Path.join(mount, "pg/data/PG_VERSION"),
        Path.join([Unit.path(main, :cub_files), "pq_files", "ab/f_ab/0"]),
        Path.join([Unit.path(backup, :cub_files), "pq_files", "cd/f_cd/0"])
      ]

      kept = [
        Path.join(Unit.path(main, :cub_db), "0.cub"),
        Path.join(Unit.path(main, :cub_files), "aa/key"),
        Path.join(Unit.path(backup, :cub_db), "0.cub"),
        Path.join(Unit.path(main, :pg), "data/PG_VERSION"),
        Path.join(Unit.path(main, :pq_files), "ab/f_ab/0")
      ]

      Enum.each(legacy ++ kept, &touch/1)

      assert PqReset.usb(@device) |> Enum.sort() ==
               [
                 Path.join(mount, "pg"),
                 Path.join(Unit.path(main, :cub_files), "pq_files"),
                 Path.join(Unit.path(backup, :cub_files), "pq_files")
               ]
               |> Enum.sort()

      refute Enum.any?(legacy, &File.exists?/1)
      assert Enum.all?(kept, &File.exists?/1)
    end

    test "is idempotent", %{mount: mount} do
      touch(Path.join(mount, "pg/data/PG_VERSION"))

      assert [_] = PqReset.usb(@device)
      assert [] == PqReset.usb(@device)
    end

    test "a drive with only the legacy PG reads as blank afterwards", %{mount: mount} do
      touch(Path.join(mount, "pg/data/PG_VERSION"))

      PqReset.usb(@device)

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

    test "drops legacy PG, blobs and Electric cache; keeps the unit's own", %{unit: unit} do
      legacy = [
        Path.join(unit.root, "pg/data/PG_VERSION"),
        Path.join([Unit.path(unit, :cub_files), "pq_files", "ab/f_ab/0"]),
        Path.join(unit.root, "electric/shapes")
      ]

      kept = [
        Path.join(Unit.path(unit, :cub_db), "0.cub"),
        Path.join(Unit.path(unit, :pg), "data/PG_VERSION"),
        Path.join(Unit.path(unit, :pq_files), "ab/f_ab/0"),
        Path.join(Unit.path(unit, :electric), "shapes")
      ]

      Enum.each(legacy ++ kept, &touch/1)

      assert length(PqReset.internal(unit)) == 3
      assert [] == PqReset.internal(unit)

      refute Enum.any?(legacy, &File.exists?/1)
      assert Enum.all?(kept, &File.exists?/1)
    end
  end

  defp touch(path) do
    path |> Path.dirname() |> File.mkdir_p!()
    File.write!(path, "x")
  end
end
