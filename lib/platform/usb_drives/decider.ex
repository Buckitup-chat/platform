defmodule Platform.UsbDrives.Decider do
  @moduledoc """
  Starts the drive's scenario.

  The scenario comes from `Platform.UsbDrives.Resolver`'s resolution: a role's
  supervisor, the dump override, or none for an ignored drive. This is the last
  step of a drive's boot tree, which `BootWatchdog` waits for.
  """

  use GenServer
  use Toolbox.OriginLog

  alias Platform.App.Drive.BackupDbSupervisor
  alias Platform.App.Drive.CargoSyncSupervisor
  alias Platform.App.Drive.MainDbSupervisor
  alias Platform.App.Drive.OnlinersSyncSupervisor
  alias Platform.App.Drive.UsbDriveDumpSupervisor
  alias Platform.Storage.DriveIndication

  @supervisors %{
    main: MainDbSupervisor,
    backup: BackupDbSupervisor,
    cargo: CargoSyncSupervisor,
    onliners: OnlinersSyncSupervisor
  }

  @doc "Scenario supervisor for a resolution, `nil` for an ignored drive"
  def scenario(resolution) do
    case resolution do
      {:role, role} -> supervisor_for(role)
      :dump -> UsbDriveDumpSupervisor
      :ignore -> nil
    end
  end

  def supervisor_for(role), do: Map.fetch!(@supervisors, role)

  def start_link(args) do
    GenServer.start_link(__MODULE__, args, [])
  end

  @impl true
  def init([device, opts]) do
    %{
      device: device,
      at: opts |> Keyword.fetch!(:mounted),
      scenario: opts |> Keyword.fetch!(:scenario),
      pg: opts |> Keyword.fetch!(:pg),
      next_supervisor: opts |> Keyword.fetch!(:next) |> Keyword.fetch!(:under)
    }
    |> then(&{:ok, &1, {:continue, :start}})
  end

  @impl true
  def handle_continue(:start, %{scenario: scenario} = state) do
    if scenario != CargoSyncSupervisor do
      DriveIndication.drive_reset()
    end

    if scenario do
      start(state)
    end

    {:noreply, state}
  end

  defp start(%{scenario: scenario, next_supervisor: supervisor} = state) do
    :ok =
      supervisor
      |> DynamicSupervisor.start_child({scenario, [state.device, state.at, state.pg]})
      |> case do
        {:ok, _} ->
          :ok

        error ->
          log(
            [
              "Error staring scenario #{scenario}\n",
              inspect(error, pretty: true)
            ],
            :error
          )

          error
      end
  end
end
