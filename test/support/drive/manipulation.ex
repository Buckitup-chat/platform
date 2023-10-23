defmodule Support.Drive.Manipulation do
  @moduledoc ""

  @registry Platform.Drives.Registry

  @type_folder %{
    cargo: "cargo_db",
    backup: "backup_db",
    onliners: "onliners_db",
    main: "main_db"
  }
  @supervisor_type %{
    Platform.App.Drive.MainDbSupervisor => :main,
    Platform.App.Drive.BackupDbSupervisor => :backup,
    Platform.App.Drive.CargoSyncSupervisor => :cargo,
    Platform.App.Drive.OnlinersSyncSupervisor => :onliners
  }

  alias Platform.UsbDrives.Detector

  def insert_empty_drive(drive), do: insert_drive(drive)
  def insert_main_drive(drive), do: insert_drive(drive, :main)
  def insert_cargo_drive(drive), do: insert_drive(drive, :cargo)
  def insert_backup_drive(drive), do: insert_drive(drive, :backup)
  def insert_onliners_drive(drive), do: insert_drive(drive, :onliners)

  def nothing_is_started?, do: check_scenario(0, [])
  def only_main_scenario_started?, do: check_scenario(1, main: 1)
  def only_cargo_scenario_started?, do: check_scenario(1, cargo: 1)
  def only_backup_scenario_started?, do: check_scenario(1, backup: 1)
  def only_onliners_scenario_started?, do: check_scenario(1, onliners: 1)
  def main_and_non_main_scenario_started?, do: check_scenario(2, main: 1)
  def main_and_cargo_scenario_started?, do: check_scenario(2, main: 1, cargo: 1)
  def main_and_onliners_scenario_started?, do: check_scenario(2, main: 1, onliners: 1)
  def main_and_backup_started?, do: check_scenario(2, main: 1, backup: 1)
  def main_and_backup_and_cargo_started?, do: check_scenario(3, main: 1, backup: 1, cargo: 1)
  def main_and_cargo_and_onliners_started?, do: check_scenario(3, main: 1, cargo: 1, onliners: 1)

  def await_supervision_started do
    await_till(
      fn ->
        with pid <- Process.whereis(@registry),
             true <- is_pid(pid) do
          Process.alive?(pid)
        end
      end,
      step: 100
    )
  end

  def eject_all_drives do
    get_registered_drives(Platform.App.Drive.BootSupervisor)
    |> Enum.each(fn {drive, _pid} -> Detector.eject(drive) end)

    await_till(fn ->
      [] == get_registered_drives(Platform.App.Drive.BootSupervisor)
    end)
  end

  def clean_filesystem do
    Application.get_env(:platform, :mount_path_media)
    |> Path.join("*")
    |> Path.wildcard()
    |> Enum.each(&File.rm_rf!/1)
  end

  defp insert_drive(drive, type \\ :empty) do
    Application.get_env(:platform, :mount_path_media)
    |> File.ls()

    if type != :empty do
      base = Application.get_env(:platform, :mount_path_media)

      [base, drive, @type_folder |> Map.fetch!(type)]
      |> Path.join()
      |> File.mkdir_p()
    end

    Detector.insert(drive)
    :timeout != await_scenario_for(drive)
  end

  defp await_scenario_for(drive) do
    await_till(
      fn ->
        get_drive_scenarios()
        |> Map.get(drive)
      end,
      step: 50
    )
  end

  defp get_registered_drives(stage) do
    @registry
    |> Registry.select([{{{stage, :"$1"}, :"$2", :_}, [], [{{:"$1", :"$2"}}]}])
  end

  defp get_drive_scenarios do
    Scenario
    |> get_registered_drives()
    |> Enum.map(fn {drive, pid} ->
      Supervisor.which_children(pid)
      |> case do
        [{_, _, _, [supervisor]}] -> {drive, supervisor}
        _ -> nil
      end
    end)
    |> Enum.reject(&is_nil/1)
    |> Map.new()
  end

  defp check_scenario(total, started) do
    scenarios = get_drive_scenarios()

    count = scenarios |> Enum.count()

    scheme =
      scenarios
      |> Enum.frequencies_by(&elem(&1, 1))
      |> Enum.map(fn {sup, freq} -> {Map.fetch!(@supervisor_type, sup), freq} end)
      |> MapSet.new()

    total == count and MapSet.subset?(MapSet.new(started), scheme)
  end

  defp await_till(action_fn, opts \\ []) do
    time = opts[:time] || 2000
    step = opts[:step] || 500

    cond do
      time < 0 ->
        :timeout

      x = action_fn.() ->
        x

      true ->
        Process.sleep(step)
        await_till(action_fn, time: time - step, step: step)
    end
  end
end
