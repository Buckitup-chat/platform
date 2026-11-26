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

      touch_legacy_cluster(mount)
      touch(Path.join(legacy_blobs(main), "ab/f_ab/0"))
      touch(Path.join(Unit.path(main, :cub_db), "0.cub"))
      touch(Path.join(Unit.path(main, :cub_files), "aa/key"))

      assert PqReset.usb(@device) |> Enum.sort() ==
               Enum.sort([
                 {:moved, legacy_pg(mount), Unit.path(main, :pg)},
                 {:moved, legacy_blobs(main), Unit.path(main, :pq_files)}
               ])

      refute File.exists?(legacy_pg(mount))
      refute File.exists?(legacy_blobs(main))

      assert File.read!(Path.join(Unit.path(main, :pg), "data/PG_VERSION")) == "x"
      assert File.exists?(Path.join(Unit.path(main, :pq_files), "ab/f_ab/0"))
      assert File.exists?(Path.join(Unit.path(main, :cub_db), "0.cub"))
      assert File.exists?(Path.join(Unit.path(main, :cub_files), "aa/key"))
      assert Role.from_mount(mount) == {:ok, :main}
    end

    test "the cluster goes to the resolved role; blobs stay with their own role", %{mount: mount} do
      main = Unit.usb(@device, :main)
      backup = Unit.usb(@device, :backup)

      touch_legacy_cluster(mount)
      touch(Path.join(legacy_blobs(main), "ab/f_ab/0"))
      touch(Path.join(legacy_blobs(backup), "cd/f_cd/0"))

      PqReset.usb(@device)

      assert File.exists?(Path.join(Unit.path(backup, :pg), "data/PG_VERSION"))
      refute File.exists?(Unit.path(main, :pg))
      assert File.exists?(Path.join(Unit.path(main, :pq_files), "ab/f_ab/0"))
      assert File.exists?(Path.join(Unit.path(backup, :pq_files), "cd/f_cd/0"))
      assert Role.from_mount(mount) == {:ok, :backup}
    end

    test "removes what has no home: a role without PG", %{mount: mount} do
      cargo = Unit.usb(@device, :cargo)

      touch_legacy_cluster(mount)
      touch(Path.join(legacy_blobs(cargo), "ab/f_ab/0"))
      touch(Path.join(Unit.path(cargo, :cub_db), "0.cub"))

      assert PqReset.usb(@device) |> Enum.sort() ==
               Enum.sort([{:removed, legacy_pg(mount)}, {:removed, legacy_blobs(cargo)}])

      assert File.ls!(Path.join(mount, Role.dir(:cargo))) |> Enum.sort() ==
               ["v.10.1", "v.10.1_files"]

      assert File.ls!(Unit.path(cargo, :cub_files)) == []
    end

    test "the unit's own copy wins over the legacy one", %{mount: mount} do
      main = Unit.usb(@device, :main)

      touch_legacy_cluster(mount)
      File.mkdir_p!(Unit.path(main, :cub_db))
      File.mkdir_p!(Path.join(Unit.path(main, :pg), "data"))
      File.write!(Path.join(Unit.path(main, :pg), "data/PG_VERSION"), "own")

      assert [{:removed, legacy_pg(mount)}] == PqReset.usb(@device)
      assert File.read!(Path.join(Unit.path(main, :pg), "data/PG_VERSION")) == "own"
    end

    test "is idempotent", %{mount: mount} do
      touch_legacy_cluster(mount)
      Unit.usb(@device, :main) |> Unit.path(:cub_db) |> File.mkdir_p!()

      assert [{:moved, _, _}] = PqReset.usb(@device)
      assert [] == PqReset.usb(@device)
    end

    test "a drive with only the legacy PG reads as blank afterwards", %{mount: mount} do
      touch_legacy_cluster(mount)

      assert [{:removed, _}] = PqReset.usb(@device)

      assert File.ls!(mount) == []
      assert Role.from_mount(mount) == :blank
    end
  end

  describe "usb/1 on a crafted drive" do
    setup do
      outside = unique_tmp_dir("pq_reset_outside")
      touch(Path.join(outside, "pq_files/ab/f_ab/0"))
      touch_legacy_cluster(outside)
      on_exit(fn -> File.rm_rf!(outside) end)

      %{outside: outside, main: Unit.usb(@device, :main)}
    end

    test "a symlinked v.10.1_files leaves the link target untouched", ctx do
      link(ctx.outside, Unit.path(ctx.main, :cub_files))

      assert [{:skipped, legacy_blobs(ctx.main)}] == PqReset.usb(@device)
      assert File.exists?(Path.join(ctx.outside, "pq_files/ab/f_ab/0"))
    end

    test "a symlinked pq_files leaves the link target untouched", ctx do
      blobs = legacy_blobs(ctx.main)
      link(Path.join(ctx.outside, "pq_files"), blobs)

      assert [{:skipped, blobs}] == PqReset.usb(@device)
      assert {:ok, %File.Stat{type: :symlink}} = File.lstat(blobs)
      assert File.exists?(Path.join(ctx.outside, "pq_files/ab/f_ab/0"))
    end

    test "a symlinked role dir leaves the link target untouched", ctx do
      nest_blobs_under_cub_files(ctx.outside)
      link(ctx.outside, Path.join(ctx.mount, Role.dir(:main)))

      assert [{:skipped, _}] = PqReset.usb(@device)
      assert File.exists?(Path.join(ctx.outside, "v.10.1_files/pq_files/ab/f_ab/0"))
    end

    test "the cluster doesn't move into a symlinked role dir", ctx do
      touch_legacy_cluster(ctx.mount)
      File.rm_rf!(legacy_pg(ctx.outside))
      File.mkdir_p!(Path.join(ctx.outside, "v.10.1"))
      link(ctx.outside, Path.join(ctx.mount, Role.dir(:main)))

      assert [{:skipped, legacy_pg(ctx.mount)}] == PqReset.usb(@device)
      assert File.exists?(Path.join(ctx.mount, "pg/data/PG_VERSION"))
      refute File.exists?(legacy_pg(ctx.outside))
    end

    test "a symlinked pg is left alone", ctx do
      link(legacy_pg(ctx.outside), legacy_pg(ctx.mount))
      File.mkdir_p!(Unit.path(ctx.main, :cub_db))

      assert [{:skipped, legacy_pg(ctx.mount)}] == PqReset.usb(@device)
      refute File.exists?(Unit.path(ctx.main, :pg))
      assert File.exists?(Path.join(ctx.outside, "pg/data/PG_VERSION"))
    end

    test "a pg/ without PG_VERSION is not a cluster: not moved, not deleted", ctx do
      photo = Path.join(ctx.mount, "pg/photos/1.jpg")
      touch(photo)
      File.mkdir_p!(Unit.path(ctx.main, :cub_db))

      assert [] == PqReset.usb(@device)
      assert File.exists?(photo)

      Unit.usb(@device, :cargo) |> Unit.path(:cub_db) |> File.mkdir_p!()
      File.rm_rf!(Path.join(ctx.mount, Role.dir(:main)))

      assert [] == PqReset.usb(@device)
      assert File.exists?(photo)
    end
  end

  defp nest_blobs_under_cub_files(role_dir) do
    File.mkdir_p!(Path.join(role_dir, "v.10.1_files"))
    File.rename!(Path.join(role_dir, "pq_files"), Path.join(role_dir, "v.10.1_files/pq_files"))
  end

  describe "internal/1" do
    setup do
      root = unique_tmp_dir("pq_reset_internal")
      on_exit(fn -> File.rm_rf!(root) end)

      %{unit: %Unit{id: :internal, role: :internal, root: root}}
    end

    test "moves legacy PG, blobs and Electric cache under the role dir", %{unit: unit} do
      touch_legacy_cluster(unit.root)
      touch(Path.join(legacy_blobs(unit), "ab/f_ab/0"))
      touch(Path.join(unit.root, "electric/shapes"))
      touch(Path.join(Unit.path(unit, :cub_db), "0.cub"))

      assert [{:moved, _, _}, {:moved, _, _}, {:moved, _, _}] = PqReset.internal(unit)
      assert [] == PqReset.internal(unit)

      refute File.exists?(legacy_pg(unit.root))
      refute File.exists?(Path.join(unit.root, "electric"))
      assert File.exists?(Path.join(Unit.path(unit, :pg), "data/PG_VERSION"))
      assert File.exists?(Path.join(Unit.path(unit, :pq_files), "ab/f_ab/0"))
      assert File.exists?(Path.join(Unit.path(unit, :electric), "shapes"))
      assert File.exists?(Path.join(Unit.path(unit, :cub_db), "0.cub"))
    end

    test "the unit's own copies win", %{unit: unit} do
      touch_legacy_cluster(unit.root)
      touch(Path.join(Unit.path(unit, :pg), "data/PG_VERSION"))

      assert [{:removed, _}] = PqReset.internal(unit)
      assert File.exists?(Path.join(Unit.path(unit, :pg), "data/PG_VERSION"))
    end
  end

  # Helpers

  defp legacy_pg(root), do: Path.join(root, "pg")
  defp legacy_blobs(unit), do: Path.join(Unit.path(unit, :cub_files), "pq_files")
  defp touch_legacy_cluster(root), do: touch(Path.join(legacy_pg(root), "data/PG_VERSION"))

  defp unique_tmp_dir(prefix),
    do: Path.join(System.tmp_dir!(), "#{prefix}_#{System.unique_integer([:positive])}")

  defp link(target, path) do
    path |> Path.dirname() |> File.mkdir_p!()
    File.ln_s!(target, path)
  end

  defp touch(path) do
    path |> Path.dirname() |> File.mkdir_p!()
    File.write!(path, "x")
  end
end
