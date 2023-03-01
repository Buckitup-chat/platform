defmodule Platform.App.Sync.Onliners.LogicTest do
  use ExUnit.Case, async: true

  alias Chat.RoomInvites
  alias Chat.Utils.StorageId
  alias Chat.Memo
  alias Chat.Files

  alias Chat.{
    Card,
    ChunkedFiles,
    Db,
    Dialogs,
    FileIndex,
    Identity,
    MemoIndex,
    Messages,
    RoomInviteIndex,
    Rooms,
    User,
    Utils
  }

  alias Chat.Db.{BackupDb, BackupDbSupervisor, ChangeTracker, InternalDb, Switching}
  alias Phoenix.PubSub
  alias Platform.App.Sync.Onliners.{Logic, OnlinersDynamicSupervisor}
  alias Platform.App.Sync.OnlinersSyncSupervisor.Tasks
  alias Support.FakeData

  setup do
    on_exit(fn ->
      Switching.set_default(InternalDb)
    end)
  end

  test "syncs online users" do
    DynamicSupervisor.start_link(name: OnlinersDynamicSupervisor, strategy: :one_for_one)
    full_path = "#{Db.file_path()}-onliners"
    BackupDbSupervisor.start_link(full_path)
    File.mkdir(full_path)

    Switching.set_default(BackupDb)

    bob = User.login("Bob")
    User.register(bob)
    bob_card = Card.from_identity(bob)

    bob_dialog = Dialogs.find_or_open(bob, bob_card)

    {bob_msg_index, bob_message} =
      "Bob talking to himself again"
      |> Messages.Text.new(1)
      |> Dialogs.add_new_message(bob, bob_dialog)

    ChangeTracker.await()

    assert %Dialogs.PrivateMessage{content: "Bob talking to himself again"} =
             Dialogs.read_message(bob_dialog, {bob_msg_index, bob_message.id}, bob)

    Switching.set_default(InternalDb)

    assert catch_error(Dialogs.read_message(bob_dialog, {bob_msg_index, bob_message.id}, bob))

    alice = User.login("Alice")
    User.register(alice)
    alice_key = Identity.pub_key(alice)

    User.register(bob)

    charlie = User.login("Charlie")
    User.register(charlie)
    charlie_card = Card.from_identity(charlie)
    charlie_key = Identity.pub_key(charlie)
    charlie_hash = Utils.hash(charlie_key)

    alice_bob_dialog = Dialogs.find_or_open(alice, bob_card)

    bob_alice_msg =
      "-"
      |> String.duplicate(151)
      |> Messages.Text.new(1)
      |> Dialogs.add_new_message(bob, alice_bob_dialog)
      |> MemoIndex.add(alice_bob_dialog, bob)

    bob_charlie_dialog = Dialogs.find_or_open(bob, charlie_card)

    "Bob greets Charlie"
    |> Messages.Text.new(1)
    |> Dialogs.add_new_message(bob, bob_charlie_dialog)

    {first_room_identity, first_room} = Rooms.add(alice, "Alice, Bob and Charlie room", :request)
    first_room_hash = Utils.hash(first_room.pub_key)

    room_invite =
      first_room_identity
      |> Messages.RoomInvite.new()
      |> Dialogs.add_new_message(alice, alice_bob_dialog)
      |> RoomInviteIndex.add(alice_bob_dialog, alice)

    {room_invite_key, room_invite_secret} =
      Dialogs.read_message(alice_bob_dialog, room_invite, alice)
      |> Map.fetch!(:content)
      |> Utils.StorageId.from_json()

    Rooms.add_request(first_room_hash, charlie, 1)
    Rooms.approve_request(first_room_hash, charlie_hash, first_room_identity, [])
    Rooms.join_approved_request(first_room_identity, charlie)

    %Messages.File{data: image_data} = image = FakeData.image("1.pp")
    [first_file_key, encoded_chunk_secret, _, _, _, _] = image_data
    chunk_secret = Base.decode64!(encoded_chunk_secret)

    {first_image_message_index, first_image_message} =
      image
      |> Map.put(:timestamp, 4)
      |> Rooms.add_new_message(charlie, first_room.pub_key)

    FileIndex.save(
      first_file_key,
      Utils.hash(first_room.pub_key),
      first_image_message.id,
      chunk_secret
    )

    first_file_secret = ChunkedFiles.new_upload(first_file_key)
    ChunkedFiles.save_upload_chunk(first_file_key, {0, 17}, "some part of info ")
    ChangeTracker.await({:file_chunk, first_file_key, 0, 17})
    ChunkedFiles.save_upload_chunk(first_file_key, {18, 29}, "another part")

    {second_room_identity, second_room} = Rooms.add(bob, "Bob and Charlie room")
    second_room_hash = Utils.hash(second_room.pub_key)
    Rooms.Registry.await_saved(second_room_hash)
    Rooms.add_request(second_room_hash, charlie, 1)
    Rooms.approve_request(second_room_hash, charlie_hash, second_room_identity, [])
    Rooms.join_approved_request(second_room_identity, charlie)

    {bob_second_room_message_index, bob_second_room_message} =
      "Hello second room from Bob"
      |> Messages.Text.new(1)
      |> Rooms.add_new_message(bob, second_room.pub_key)

    ChangeTracker.await()

    PubSub.subscribe(Chat.PubSub, "platform_onliners->chat_onliners")

    Task.Supervisor.start_link(name: Tasks)
    Logic.start_link(Tasks)

    assert_receive "get_user_keys"

    keys = MapSet.new([alice_key, first_room.pub_key])

    PubSub.broadcast(Chat.PubSub, "chat_onliners->platform_onliners", {:user_keys, keys})

    :timer.sleep(3000)

    users_count = length(User.list())
    assert catch_error(Dialogs.read_message(bob_dialog, {bob_msg_index, bob_message.id}, bob))

    Switching.set_default(BackupDb)

    assert length(User.list()) == users_count

    {_, list} = Rooms.list([first_room_hash])
    assert Enum.any?(list, &(&1.hash == first_room_hash))

    {_, list} = Rooms.list([second_room_hash])
    refute Enum.any?(list, &(&1.hash == second_room_hash))

    assert ["Alice, Bob and Charlie room", _] =
             RoomInvites.get(room_invite_key, room_invite_secret)

    memo =
      Dialogs.read_message(alice_bob_dialog, bob_alice_msg, bob)
      |> Map.get(:content)
      |> StorageId.from_json()
      |> Memo.get()

    assert memo == String.duplicate("-", 151)

    assert [^first_file_key, ^encoded_chunk_secret, _, _, _, _] =
             Rooms.read_message(
               {first_image_message_index, first_image_message.id},
               first_room_identity,
               &User.id_map_builder/1
             )
             |> Map.get(:content)
             |> StorageId.from_json()
             |> Files.get()

    assert ChunkedFiles.read({first_file_key, first_file_secret}) ==
             "some part of info another part"

    assert catch_error(
             Rooms.read_message(
               {bob_second_room_message_index, bob_second_room_message.id},
               second_room_identity,
               &User.id_map_builder/1
             )
           )
  end
end
