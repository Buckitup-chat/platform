defmodule Platform.App.Sync.UsbDriveDumpSupervisorTest do
  use ExUnit.Case, async: false

  alias Chat.{
    Db,
    Identity,
    Rooms,
    User
  }

  alias Chat.Db.{ChangeTracker, Common}
  alias Chat.Rooms.{Message, PlainMessage}
  alias Chat.Sync.UsbDriveDumpRoom
  alias Phoenix.PubSub

  @cub_db_file Application.compile_env(:chat, :cub_db_file)
  @mount_path Application.compile_env(:platform, :mount_path_media)

  setup do
    CubDB.clear(Db.db())
    UsbDriveDumpRoom.remove()
    Common.put_chat_db_env(:flags, [])

    File.rm_rf!(@cub_db_file)

    "#{@mount_path}/DCIM/**/.DS_Store"
    |> Path.wildcard(match_dot: true)
    |> Enum.each(&File.rm/1)

    start_supervised!(
      {DynamicSupervisor, name: Platform.App.Media.DynamicSupervisor, strategy: :one_for_one}
    )

    :ok
  end

  test "dumps files from the USB drive into the room" do
    PubSub.subscribe(Chat.PubSub, "chat::usb_drive_dump_room")

    operator = User.login("Operator")
    User.register(operator)

    {room_identity, room} = Rooms.add(operator, "Room", :public)
    room_key = room_identity |> Identity.pub_key()

    room_key
    |> Base.encode16(case: :lower)
    |> then(&PubSub.subscribe(Chat.PubSub, "room:#{&1}"))

    Rooms.add(operator, "Other room", :public)

    UsbDriveDumpRoom.activate(room_key, room_identity)

    assert_receive {:update_usb_drive_dump_room,
                    %UsbDriveDumpRoom{
                      identity: ^room_identity,
                      pub_key: ^room_key,
                      status: :pending
                    }}

    ChangeTracker.await()

    File.touch(Path.join([@mount_path, "DCIM", "Other", "1234.txt"]), 1_681_263_987)

    File.touch(
      Path.join([@mount_path, "DCIM", "Запись экрана 2022-12-02 в 15.55.32.mov"]),
      1_681_264_949
    )

    File.touch(
      Path.join([@mount_path, "DCIM", "100PHOTO", "Снимок экрана 2023-04-08 в 09.28.19.png"]),
      1_681_302_707
    )

    assert {:ok, _pid} =
             Platform.App.Media.DynamicSupervisor
             |> DynamicSupervisor.start_child({Platform.App.Media.Supervisor, [nil]})

    assert [usb_drive_dump: true] = Common.get_chat_db_env(:flags)

    assert_receive {:update_usb_drive_dump_room,
                    %UsbDriveDumpRoom{
                      identity: ^room_identity,
                      pub_key: ^room_key,
                      status: :dumping
                    }}

    assert_receive {:update_usb_drive_dump_room,
                    %UsbDriveDumpRoom{
                      identity: ^room_identity,
                      pub_key: ^room_key,
                      status: :complete
                    }}

    assert_receive {:room,
                    {:new_message,
                     {1,
                      %Message{
                        timestamp: 1_681_263_987,
                        author_key: ^room_key,
                        type: :file
                      }}}},
                   5000

    assert_receive {:room,
                    {:new_message,
                     {2,
                      %Message{
                        timestamp: 1_681_264_949,
                        author_key: ^room_key,
                        type: :video
                      }}}},
                   5000

    assert_receive {:room,
                    {:new_message,
                     {3,
                      %Message{
                        timestamp: 1_681_302_707,
                        author_key: ^room_key,
                        type: :image
                      }}}},
                   5000

    assert [
             %PlainMessage{
               index: 1,
               timestamp: 1_681_263_987,
               author_key: ^room_key,
               type: :file
             },
             %PlainMessage{
               index: 2,
               timestamp: 1_681_264_949,
               author_key: ^room_key,
               type: :video
             },
             %PlainMessage{
               index: 3,
               timestamp: 1_681_302_707,
               author_key: ^room_key,
               type: :image
             }
           ] = Rooms.read(room, room_identity)
  end
end
