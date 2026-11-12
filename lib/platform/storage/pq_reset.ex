defmodule Platform.Storage.PqReset do
  @moduledoc """
  One-time PQ reset (`pq_storage_units.proposed.md` §7.2).

  Before storage units, PostgreSQL, chunk blobs and the Electric cache lived
  outside the role dir. They are dropped (early stage) and rebuilt under
  `<root>/<role_dir>/` on first boot; CubDB data is kept.

  | Unit     | Removes                                                        |
  |----------|----------------------------------------------------------------|
  | internal | `<root>/pg`, `<cub_files>/pq_files`, `<root>/electric`         |
  | USB      | `<mount>/pg`, `<mount>/<role_dir>/v.10.1_files/pq_files`       |

  Runs in Resolve, before any engine starts: `Resolver` for a USB drive, the
  first step of `DatabaseSupervisor` for the internal unit. Idempotent - only
  legacy locations are touched, so a second boot removes nothing. Remove this
  module once the fleet is migrated.

  As a stage step (`{:step, name, {PqReset, unit: unit}}`) it resets `unit`
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

  @doc "Removes the legacy PQ generation of the internal unit. Returns the removed paths."
  @spec internal(Unit.t()) :: [Path.t()]
  def internal(%Unit{role: :internal, root: root} = unit) do
    [
      Path.join(root, @legacy_pg),
      legacy_pq_files(unit),
      Path.join(root, @legacy_electric)
    ]
    |> remove()
  end

  @doc """
  Removes the legacy PQ generation of a USB drive, before its role is resolved:
  blobs under every role dir, so a legacy multi-role drive is cleaned too.
  Returns the removed paths.
  """
  @spec usb(String.t()) :: [Path.t()]
  def usb(device) when is_binary(device) do
    pq_files =
      Role.all()
      |> List.delete(:internal)
      |> Enum.map(&(device |> Unit.usb(&1) |> legacy_pq_files()))

    [Path.join(Unit.root(device), @legacy_pg) | pq_files]
    |> remove()
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

  defp remove(paths) do
    paths
    |> Enum.filter(&File.exists?/1)
    |> Enum.map(fn path ->
      File.rm_rf!(path)
      log("PQ reset: removed #{path}", :info)
      path
    end)
  end
end
