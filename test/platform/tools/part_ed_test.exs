defmodule Platform.Tools.PartEdTools do
  use ExUnit.Case, async: true

  alias Platform.Tools.PartEd

  test "mmc size print should parse well" do
    assert 3_904_897_024 == PartEd.size("mmcblk0", &device_details_fixture/1)
    assert 536_870_912 == PartEd.size("mmcblk0p3", &device_details_fixture/1)
  end

  test "sda size print should parse well" do
    assert 4_005_527_552 = PartEd.size("sda", &device_details_fixture/1)
    assert 4_003_140_608 = PartEd.size("sda1", &device_details_fixture/1)
  end

  defp device_details_fixture("sda") do
    str = """
    Model: Kingston DT 101 II (scsi)
    Disk /dev/sda: 4005527552B
    Sector size (logical/physical): 512B/512B
    Partition Table: msdos
    Disk Flags:

    Number  Start        End          Size         Type     File system  Flags
     1      31744B       4003172351B  4003140608B  primary  fat32        lba
            4003172352B  4005527551B  2355200B              Free Space

    """

    {:ok, str |> PartEd.Print.parse()}
  end

  defp device_details_fixture("mmcblk0") do
    str = """
    Model: SD SA04G (sd/mmc)
    Disk /dev/mmcblk0: 3904897024B
    Sector size (logical/physical): 512B/512B
    Partition Table: msdos
    Disk Flags:

    Number  Start       End          Size         Type     File system  Flags
     1      32256B      19810815B    19778560B    primary  fat16        boot, lba
            19810816B   39589887B    19779072B             Free Space
     2      39589888B   187580415B   147990528B   primary
            187580416B  335570943B   147990528B            Free Space
     3      335570944B  872441855B   536870912B   primary
            872441856B  3904897023B  3032455168B           Free Space
    """

    {:ok, str |> PartEd.Print.parse()}
  end
end
