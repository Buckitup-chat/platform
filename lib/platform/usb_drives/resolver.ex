defmodule Platform.UsbDrives.Resolver do
  @moduledoc """
  Resolves a mounted drive's role before any engine starts.

  The role dir on the drive (`Chat.Storage.Role.from_mount/1`) is the source of
  truth. A blank drive gets a role from `MediaSettings` - after the optional
  `optimize_fs`, which can only run here, while nothing is written yet - and the
  role dir is created so the role sticks. A role that is already taken is
  ignored, as before: no PG, no scenario, no indication.

  The resolution builds the rest of the boot tree (`:tree` option), so PG stages
  run only for roles with `:pg`. The one-time PQ relocation (`PqReset`, §7.2)
  runs before the role is read. See `pq_storage_units.proposed.md` §1.5, §3.
  """
  use GracefulGenServer, timeout: :timer.minutes(1)
  use Toolbox.OriginLog

  alias Chat.Admin.MediaSettings
  alias Chat.AdminRoom
  alias Chat.Storage.Role
  alias Chat.Sync.UsbDriveDumpRoom
  alias Platform.Storage.PqReset
  alias Platform.UsbDrives.Decider

  @type resolution :: {:role, Role.t()} | :dump | :ignore

  @impl true
  def on_init(opts) do
    %{
      device: opts |> Keyword.fetch!(:device),
      path: opts |> Keyword.fetch!(:at),
      optimizer: opts |> Keyword.fetch!(:optimizer),
      tree: opts |> Keyword.fetch!(:tree),
      under: opts |> Keyword.fetch!(:under)
    }
    |> tap(fn _ -> send(self(), :resolve) end)
  end

  @impl true
  def on_msg(:resolve, %{device: device, tree: tree, under: under} = state) do
    resolution = resolve(state)
    log("#{device} resolved as #{inspect(resolution)}", :info)

    Platform.start_next_stage(under, tree.(resolution))
    {:noreply, state}
  end

  @impl true
  def on_exit(_reason, _state), do: :ok

  # Dump is a scenario, not a role: a camera card gets no role dir and no PG.
  # The PQ reset runs first: the legacy cluster moves into the role dir, and a drive
  # with only `<mount>/pg` (no role dir) reads as blank.
  defp resolve(%{device: device, path: path} = state) do
    if UsbDriveDumpRoom.get() do
      :dump
    else
      PqReset.usb(device)
      path |> Role.from_mount() |> from_disk(state)
    end
  end

  defp from_disk(found, %{path: path, optimizer: optimizer}) do
    case found do
      {:ok, role} ->
        unless_taken(role)

      :blank ->
        blank_role()
        |> unless_taken()
        |> tap(fn
          {:role, role} -> settle_blank(path, role, optimizer)
          :ignore -> :ok
        end)

      {:error, {:multiple_roles, roles}} ->
        log("#{path} has several roles with PG #{inspect(roles)}, ignoring the drive", :error)
        :ignore
    end
  end

  defp unless_taken(role) do
    if taken?(role) do
      log("role #{role} is taken, ignoring the drive", :info)
      :ignore
    else
      {:role, role}
    end
  end

  # At most one unit per role: its scenario supervisor is up
  defp taken?(role), do: role |> Decider.supervisor_for() |> Process.whereis() |> is_pid()

  defp blank_role do
    %MediaSettings{main: create_main?, functionality: functionality} =
      AdminRoom.get_media_settings()

    if create_main? and not taken?(:main), do: :main, else: functionality
  end

  defp settle_blank(path, role, optimizer) do
    %MediaSettings{optimize: optimize?} = AdminRoom.get_media_settings()

    if optimize? and empty?(path) do
      optimizer.optimize(path)
    end

    path |> Path.join(Role.dir(role)) |> File.mkdir_p!()
  end

  # No role dir is not enough to format: a camera card has DCIM/
  defp empty?(path), do: path |> File.ls!() |> Enum.empty?()
end
