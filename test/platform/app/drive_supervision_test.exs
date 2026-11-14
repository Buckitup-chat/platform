defmodule DriveSupervisionTest do
  use ExUnit.Case

  import Support.Drive.Manipulation

  alias Chat.Storage.Default

  @drive "sde1"

  test "main dies by its plan" do
    prepare()
    await_main_set_up_completely(@drive)

    kill_plan(@drive)
    Process.sleep(100)
    await_main_set_up_completely(@drive)

    # and one more time to exceed the scenario's restart intensity
    kill_plan(@drive)
    Process.sleep(100)
    await_main_set_up_completely(@drive)

    cleanup()
  end

  test "main dies by first stage in scenario" do
    prepare()
    # print_supervision_tree()

    kill_a_child_in_scenario(@drive)
    Process.sleep(100)
    await_main_set_up_completely(@drive)
    # print_supervision_tree()

    kill_a_child_in_scenario(@drive)
    Process.sleep(100)
    await_main_set_up_completely(@drive)
    # print_supervision_tree()

    cleanup()
  end

  test "main dies in mounter" do
    prepare()
    # print_supervision_tree()

    kill_mounter(@drive)
    Process.sleep(100)
    await_main_set_up_completely(@drive)
    # print_supervision_tree()

    kill_mounter(@drive)
    Process.sleep(100)
    await_main_set_up_completely(@drive)
    # print_supervision_tree()

    cleanup()
  end

  defp kill_plan(drive) do
    {_, pid, _, _} =
      get_drive_scenarios()
      |> Map.get(drive)
      |> Supervisor.which_children()
      |> List.keyfind(Platform.Storage.MainPlan, 0)

    Process.exit(pid, :test)
  end

  defp kill_a_child_in_scenario(drive) do
    {_, pid, _, _} =
      get_drive_scenarios()
      |> Map.get(drive)
      |> Supervisor.which_children()
      |> List.first()

    Process.exit(pid, :test)
  end

  defp kill_mounter(drive) do
    get_registered_drives(Healed)
    |> Map.new()
    |> Map.get(drive)
    |> stage_children()
    |> Enum.reject(&match?({_, DynamicSupervisor}, &1))
    |> List.first()
    |> elem(0)
    |> Process.exit(:test)
  end

  # Every scenario child is up and the attach plan has made main the Default
  defp await_main_set_up_completely(drive) do
    refute :timeout ==
             await_till(
               fn ->
                 scenario_children_alive?(drive) and
                   Default.unit().role == :main
               end,
               step: 500,
               time: 20_000
             )
  end

  defp scenario_children_alive?(drive) do
    case get_drive_scenarios() |> Map.get(drive) do
      nil ->
        false

      scenario ->
        scenario
        |> Supervisor.which_children()
        |> Enum.all?(fn {_, pid, _, _} -> is_pid(pid) and Process.alive?(pid) end)
    end
  catch
    # The supervisor went down while being asked: the tree is still restarting
    :exit, _ -> false
  end

  defp stage_children(pid) do
    with true <- is_pid(pid),
         [{_, s_pid, _, [Supervisor]}] <- Supervisor.which_children(pid),
         child_specs <- Supervisor.which_children(s_pid),
         false <- Enum.empty?(child_specs) do
      child_specs
      |> Enum.map(fn {_, child_pid, _, [child_module]} -> {child_pid, child_module} end)
    else
      _ -> false
    end
  catch
    # The supervisor went down while being asked: the tree is still restarting
    :exit, _ -> false
  end

  defp prepare do
    await_supervision_started()
    assert nothing_is_started?()
    insert_main_drive(@drive)
  end

  defp cleanup do
    eject_all_drives()
    clean_filesystem()
  end

  defp print_supervision_tree do
    Platform.App.DeviceSupervisor
    |> Process.whereis()
    |> build_supervision_tree()
    |> inspect(limit: :infinity, pretty: true)
    |> IO.puts()
  end

  defp build_supervision_tree(supervisor) do
    supervisor
    |> Supervisor.which_children()
    |> Enum.map(fn
      {_, pid, :worker, spec} -> {pid, spec}
      {_, pid, :supervisor, _} -> {pid, pid |> build_supervision_tree()}
    end)
    |> Map.new()
  end
end
