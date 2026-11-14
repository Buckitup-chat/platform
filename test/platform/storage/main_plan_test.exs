defmodule Platform.Storage.MainPlanTest do
  use ExUnit.Case, async: false

  import Support.Drive.Manipulation

  alias Chat.Storage.Default
  alias Chat.Storage.Links
  alias Chat.Storage.Unit
  alias Platform.Storage.MainPlan

  @drive "sdf1"

  setup do
    await_supervision_started()

    on_exit(fn ->
      eject_all_drives()
      clean_filesystem()
    end)
  end

  test "attach makes main the Default, eject brings internal back without leftover slots" do
    attach()
    assert :replicating == Links.status({:main, :internal})
    assert :stopped == Links.status({:internal, :main})

    eject()
    assert :stopped == Links.status({:main, :internal})
    assert [] == link_slots_on_internal()
  end

  # Rows the drive alone holds come back through the `main ~> internal` bootstrap
  # (tested in chat: Chat.Storage.Link.BootstrapTest). Here: it runs before the switch.
  test "attach pulls drive-only data back before main becomes the Default" do
    internal = Unit.internal()
    main = Unit.usb(@drive, :main)
    steps = MainPlan.plan(:main_attach, internal, main)

    pull_back = Enum.find_index(steps, &match?({:bootstrap, %{from: ^main, to: ^internal}}, &1))
    switch = Enum.find_index(steps, &match?({:switch_default, ^main}, &1))

    assert pull_back < switch

    assert [{:stop, %{from: ^main, to: ^internal}}, {:switch_default, ^internal}] =
             MainPlan.plan(:main_eject, internal, main)
  end

  defp attach do
    insert_main_drive(@drive)
    await_default(:main)
  end

  defp eject do
    eject_all_drives()
    await_default(:internal)
  end

  defp await_default(role),
    do: refute(:timeout == await_till(fn -> Default.unit().role == role end, time: 20_000))

  # Slots links create on internal are named "<to>_from_internal"
  defp link_slots_on_internal do
    "SELECT slot_name FROM pg_replication_slots WHERE slot_name LIKE '%_from_internal'"
    |> Chat.Repo.query!()
    |> Map.fetch!(:rows)
  end
end
