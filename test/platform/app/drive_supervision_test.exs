defmodule DriveSupervisionTest do
  use ExUnit.Case

  import Support.Drive.Manipulation

  @drive "main_drive"

  test "main dies by last stage" do
    prepare()
    await_main_set_up_completely(@drive)
    # print_supervision_tree()

    kill_last_stage_children(@drive)
    Process.sleep(100)
    await_main_set_up_completely(@drive)
    # print_supervision_tree()

    # and one more time to trigger prev stage killing
    kill_last_stage_children(@drive)
    Process.sleep(100)
    await_main_set_up_completely(@drive)
    # print_supervision_tree()

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

  defp kill_last_stage_children(drive) do
    get_drive_scenarios()
    |> Map.get(drive)
    |> find_next_stage()
    |> stage_children()
    |> Enum.map(&elem(&1, 0))
    |> Enum.each(&Process.exit(&1, :test))
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

  defp await_main_set_up_completely(drive) do
    refute :timeout ==
             await_till(
               fn ->
                 get_drive_scenarios()
                 |> Map.get(drive)
                 |> find_next_stage()
                 |> stage_children()
                 |> case do
                   false ->
                     false

                   list ->
                     list
                     |> Enum.map(&elem(&1, 0))
                     |> Enum.all?(&Process.alive?/1)
                 end
               end,
               step: 500,
               time: 10_000
             )
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
  end

  defp find_next_stage(supervisor) do
    with sup_pid <- Process.whereis(supervisor),
         true <- is_pid(sup_pid),
         sup_child_specs <- Supervisor.which_children(sup_pid),
         [{_, pid, _, _} | _] <-
           Enum.filter(sup_child_specs, &(elem(&1, 3) == [DynamicSupervisor])) do
      pid
    else
      _ -> false
    end
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
    |> IO.inspect(limit: :infinity)
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
