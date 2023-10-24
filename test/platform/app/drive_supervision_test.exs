defmodule DriveSupervisionTest do
  use ExUnit.Case

  import Support.Drive.Manipulation

  test "main dies by last stage" do
    await_supervision_started()
    assert nothing_is_started?()
    insert_main_drive("main_drive")
    await_main_set_up_completely("main_drive")

    kill_last_stage_children("main_drive")
    Process.sleep(100)
    await_main_set_up_completely("main_drive")

    # and one more time to trigger prev stage killing
    kill_last_stage_children("main_drive")
    Process.sleep(100)
    await_main_set_up_completely("main_drive")

    eject_all_drives()
    clean_filesystem()
  end

  test "main dies by first stage in scenario"
  test "main dies in mounter"
  test "main dies in indication"

  defp kill_last_stage_children(drive) do
    get_drive_scenarios()
    |> Map.get(drive)
    |> find_next_stage()
    |> stage_children()
    |> Enum.map(&elem(&1, 0))
    |> Enum.each(&Process.exit(&1, :test))
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
end
