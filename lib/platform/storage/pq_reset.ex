defmodule Platform.Storage.PqReset do
  @moduledoc """
  One-time PQ relocation (`pq_storage_units.done.md` §7.2).

  Before storage units, PostgreSQL, chunk blobs and the Electric cache lived
  outside the role dir. They are moved under `<root>/<role_dir>/`, so PQ data
  survives the layout change; CubDB data is not touched.

  | Unit     | Legacy                                       | Moved to                  |
  |----------|----------------------------------------------|---------------------------|
  | internal | `<root>/pg`                                  | `<root>/db/pg`            |
  | internal | `<cub_files>/pq_files`                       | `<root>/db/pq_files`      |
  | internal | `<root>/electric`                            | `<root>/db/electric`      |
  | USB      | `<mount>/pg`                                 | `<mount>/<role_dir>/pg`   |
  | USB      | `<mount>/<role_dir>/v.10.1_files/pq_files`   | `<mount>/<role_dir>/pq_files` |

  The cluster keeps its port and socket dir (`Unit.pg_port/1`, `Unit.pg_run/1`
  derive from the device, not the path), so it starts as is. A USB cluster goes to
  the role the drive resolves to (`Role.from_mount/1`).

  A legacy location is removed instead when it has no home: the role lacks the
  capability (cargo, onliners), the drive has no role dir, the unit already has
  its own copy, or the rename fails (e.g. across filesystems).

  Runs in Resolve, before any engine starts: `Resolver` for a USB drive, the
  first step of `DatabaseSupervisor` for the internal unit. Idempotent - only
  legacy locations are touched, so a second boot does nothing. Remove this
  module once the fleet is migrated.

  As a stage step (`{:step, name, {PqReset, unit: unit}}`) it relocates `unit`
  and starts the next stage.
  """
  use GracefulGenServer, timeout: :timer.minutes(1)
  use Toolbox.OriginLog

  alias Chat.Storage.Role
  alias Chat.Storage.Unit

  # Legacy segments - the pre-unit layout, known nowhere else
  @legacy_pg "pg"
  @legacy_pq_files "pq_files"
  @legacy_electric "electric"

  @type outcome :: {:moved, Path.t(), Path.t()} | {:removed, Path.t()}

  @doc "Relocates the legacy PQ generation of the internal unit."
  @spec internal(Unit.t()) :: [outcome()]
  def internal(%Unit{role: :internal, root: root} = unit) do
    [
      {Path.join(root, @legacy_pg), Unit.path(unit, :pg)},
      {legacy_pq_files(unit), Unit.path(unit, :pq_files)},
      {Path.join(root, @legacy_electric), Unit.path(unit, :electric)}
    ]
    |> relocate()
  end

  @doc """
  Relocates the legacy PQ generation of a USB drive, before its role is resolved:
  blobs of every role dir, the cluster into the role the drive resolves to.
  """
  @spec usb(String.t()) :: [outcome()]
  def usb(device) when is_binary(device) do
    pq_files =
      Role.all()
      |> List.delete(:internal)
      |> Enum.map(&Unit.usb(device, &1))
      |> Enum.map(&{legacy_pq_files(&1), home(&1, :pq_files)})

    [{device |> Unit.root() |> Path.join(@legacy_pg), pg_home(device)} | pq_files]
    |> relocate()
  end

  @impl true
  def on_init(opts) do
    next = opts |> Keyword.fetch!(:next)

    %{
      unit: opts |> Keyword.fetch!(:unit),
      next_specs: next |> Keyword.fetch!(:run),
      next_supervisor: next |> Keyword.fetch!(:under)
    }
    |> tap(fn _ -> send(self(), :reset) end)
  end

  @impl true
  def on_msg(:reset, %{unit: unit, next_specs: specs, next_supervisor: supervisor} = state) do
    internal(unit)
    Platform.start_next_stage(supervisor, specs)
    {:noreply, state}
  end

  @impl true
  def on_exit(_reason, _state), do: :ok

  defp legacy_pq_files(unit), do: unit |> Unit.path(:cub_files) |> Path.join(@legacy_pq_files)

  # The legacy role dirs hold no `pg/` yet, so this is the priority role
  defp pg_home(device) do
    case device |> Unit.root() |> Role.from_mount() do
      {:ok, role} -> device |> Unit.usb(role) |> home(:pg)
      _ -> nil
    end
  end

  defp home(unit, resource) do
    if resource in Unit.capabilities(unit), do: Unit.path(unit, resource)
  end

  defp relocate(moves) do
    moves
    |> Enum.filter(fn {from, _to} -> File.exists?(from) end)
    |> Enum.map(fn {from, to} ->
      if to && not File.exists?(to), do: move(from, to), else: remove(from)
    end)
  end

  # postgres traverses the role dir, as `Lifecycle.Init` sets it up for a fresh cluster
  defp move(from, to) do
    parent = to |> Path.dirname() |> tap(&File.mkdir_p!/1)

    case File.rename(from, to) do
      :ok ->
        File.chmod!(parent, 0o755)
        log("PQ reset: moved #{from} to #{to}", :info)
        {:moved, from, to}

      {:error, reason} ->
        log("PQ reset: can't move #{from} to #{to} (#{inspect(reason)})", :warning)
        remove(from)
    end
  end

  defp remove(path) do
    File.rm_rf!(path)
    log("PQ reset: removed #{path}", :info)
    {:removed, path}
  end
end
