defmodule Platform.App.Sync.CargoSyncSupervisorTest do
  use ExUnit.Case, async: false

  alias Phoenix.PubSub
  alias Chat.Admin.CargoSettings

  alias Chat.{
    AdminDb,
    AdminRoom,
    Card,
    ChunkedFiles,
    Db,
    Dialogs,
    FileIndex,
    Identity,
    Messages,
    Rooms,
    User
  }

  alias Chat.Sync.CargoRoom
  alias Chat.Content.Files
  alias Chat.Db.{CargoDb, ChangeTracker, InternalDb, MediaDbSupervisor, Switching}
  alias Chat.Utils.StorageId
  alias Platform.App.Media.FunctionalityDynamicSupervisor
  alias Platform.App.Sync.CargoSyncSupervisor
  alias Support.FakeData

  @cub_db_file Application.compile_env(:chat, :cub_db_file)
  @mount_path Application.compile_env(:platform, :mount_path_media)

  setup do
    CubDB.clear(AdminDb.db())
    CubDB.clear(Db.db())
    CargoRoom.activate(nil)

    File.rm_rf!(@cub_db_file)
    File.rm_rf!(@mount_path)

    DynamicSupervisor.start_link(name: FunctionalityDynamicSupervisor, strategy: :one_for_one)

    on_exit(fn ->
      Switching.set_default(InternalDb)
    end)
  end

  test "syncs cargo room messages" do
    PubSub.subscribe(Chat.PubSub, "chat::cargo_room")
    PubSub.subscribe(Chat.PubSub, "chat::lobby")

    operator = User.login("Operator")
    User.register(operator)

    sensor = User.login("Sensor")
    User.register(sensor)
    sensor_card = Card.from_identity(sensor)
    sensor_key = Identity.pub_key(sensor)

    bob = User.login("Bob")
    User.register(bob)

    charlie = User.login("Charlie")
    User.register(charlie)
    charlie_card = Card.from_identity(charlie)

    bob_charlie_dialog = Dialogs.find_or_open(bob, charlie_card)

    {bob_charlie_msg_index, bob_charlie_message} =
      "Bob greets Charlie"
      |> Messages.Text.new(1)
      |> Dialogs.add_new_message(bob, bob_charlie_dialog)

    bob_sensor_dialog = Dialogs.find_or_open(bob, sensor_card)

    {bob_sensor_msg_index, bob_sensor_message} =
      "Bob fiddles with the sensor"
      |> Messages.Text.new(1)
      |> Dialogs.add_new_message(bob, bob_sensor_dialog)

    AdminRoom.store_cargo_settings(%CargoSettings{checkpoints: [sensor_key]})

    {cargo_room_identity, _cargo_room} = Rooms.add(operator, "Cargo room", :cargo)
    cargo_room_key = cargo_room_identity |> Identity.pub_key()
    CargoRoom.activate(cargo_room_key)

    assert_receive {:update_cargo_room, %CargoRoom{pub_key: ^cargo_room_key, status: :pending}}

    Rooms.add(operator, "Other room", :public)

    ChangeTracker.await()

    Rooms.add_request(cargo_room_key, sensor, 1)
    Rooms.approve_request(cargo_room_key, sensor_key, cargo_room_identity, [])

    %Messages.File{data: image_data} = image = FakeData.image("1.pp")
    [file_key, encoded_chunk_secret, _, _, _, _] = image_data
    chunk_secret = Base.decode64!(encoded_chunk_secret)

    {image_message_index, image_message} =
      image
      |> Map.put(:timestamp, 4)
      |> Rooms.add_new_message(sensor, cargo_room_key)

    FileIndex.save(
      file_key,
      cargo_room_key,
      image_message.id,
      chunk_secret
    )

    file_secret = ChunkedFiles.new_upload(file_key)
    ChunkedFiles.save_upload_chunk(file_key, {0, 17}, 30, "some part of info ")
    ChangeTracker.await({:file_chunk, file_key, 0, 17})
    ChunkedFiles.save_upload_chunk(file_key, {18, 29}, 30, "another part")

    {second_message_index, second_message} =
      "Hello from the sensor"
      |> Messages.Text.new(1)
      |> Rooms.add_new_message(sensor, cargo_room_key)

    ChangeTracker.await()

    FunctionalityDynamicSupervisor
    |> DynamicSupervisor.start_child({CargoSyncSupervisor, [nil]})

    assert_receive {:update_cargo_room, %CargoRoom{pub_key: ^cargo_room_key, status: :syncing}}

    DynamicSupervisor.terminate_child(
      FunctionalityDynamicSupervisor,
      CargoSyncSupervisor |> Process.whereis()
    )

    assert_receive {:update_cargo_room, %CargoRoom{pub_key: ^cargo_room_key, status: :complete}}
    assert_receive {:new_room, ^cargo_room_key}
    assert_receive {:new_user, nil}

    internal_db_users_count = length(User.list())

    path = [@mount_path, "cargo_db", Chat.Db.version_path()] |> Path.join()
    {:ok, media_db_supervisor_pid} = MediaDbSupervisor.start_link([CargoDb, path])

    Switching.set_default(CargoDb)

    assert length(User.list()) == internal_db_users_count
    assert Rooms.get(cargo_room_key)

    assert [^file_key, ^encoded_chunk_secret, _, _, _, _] =
             Rooms.read_message(
               {image_message_index, image_message.id},
               cargo_room_identity
             )
             |> Map.get(:content)
             |> StorageId.from_json()
             |> Files.get()

    assert ChunkedFiles.read({file_key, file_secret}) == "some part of info another part"

    assert Rooms.read_message(
             {second_message_index, second_message.id},
             cargo_room_identity
           )
           |> Map.get(:content) == "Hello from the sensor"

    assert catch_error(
             Dialogs.read_message(
               bob_charlie_dialog,
               {bob_charlie_msg_index, bob_charlie_message.id},
               bob
             )
           )

    assert Dialogs.read_message(
             bob_sensor_dialog,
             {bob_sensor_msg_index, bob_sensor_message.id},
             bob
           )
           |> Map.get(:content) == "Bob fiddles with the sensor"

    another_sensor = User.login("Another Sensor")
    User.register(another_sensor)
    another_sensor_key = Identity.pub_key(another_sensor)
    Rooms.add_request(cargo_room_key, another_sensor, 1)
    Rooms.approve_request(cargo_room_key, another_sensor_key, cargo_room_identity, [])

    {third_message_index, third_message} =
      "Hello from another sensor"
      |> Messages.Text.new(1)
      |> Rooms.add_new_message(another_sensor, cargo_room_key)

    ChangeTracker.await()

    Switching.set_default(InternalDb)

    {fourth_message_index, fourth_message} =
      "Hello again from the sensor"
      |> Messages.Text.new(1)
      |> Rooms.add_new_message(sensor, cargo_room_key)

    other_user = User.login("Other user")
    User.register(other_user)

    {other_room_identity, _other_room} = Rooms.add(operator, "Other room", :public)
    other_room_key = other_room_identity |> Identity.pub_key()

    {other_room_message_index, other_room_message} =
      "Hello to the other room"
      |> Messages.Text.new(1)
      |> Rooms.add_new_message(another_sensor, other_room_key)

    ChangeTracker.await()

    Process.exit(media_db_supervisor_pid, :normal)

    FunctionalityDynamicSupervisor
    |> DynamicSupervisor.start_child({CargoSyncSupervisor, [nil]})

    assert_receive {:update_cargo_room, %CargoRoom{pub_key: ^cargo_room_key, status: :syncing}}

    DynamicSupervisor.terminate_child(
      FunctionalityDynamicSupervisor,
      CargoSyncSupervisor |> Process.whereis()
    )

    assert_receive {:update_cargo_room, %CargoRoom{pub_key: ^cargo_room_key, status: :complete}}
    assert_receive {:new_room, ^cargo_room_key}
    assert_receive {:new_user, nil}

    internal_db_users_count = length(User.list())

    assert Rooms.read_message(
             {third_message_index, third_message.id},
             cargo_room_identity
           )
           |> Map.get(:content) == "Hello from another sensor"

    start_supervised!({MediaDbSupervisor, [CargoDb, path]})

    Switching.set_default(CargoDb)

    assert length(User.list()) == internal_db_users_count
    refute Rooms.get(other_room_key)

    assert Rooms.read_message(
             {fourth_message_index, fourth_message.id},
             cargo_room_identity
           )
           |> Map.get(:content) == "Hello again from the sensor"

    assert catch_error(
             Rooms.read_message(
               {other_room_message_index, other_room_message.id},
               other_room_identity
             )
           )
  end

  test "skips copying if it can't decide which room to sync" do
    operator = User.login("Operator")
    User.register(operator)

    sensor = User.login("Sensor")
    User.register(sensor)

    {cargo_room_identity, _cargo_room} = Rooms.add(operator, "First room", :public)
    cargo_room_key = cargo_room_identity |> Identity.pub_key()
    {other_room_identity, _other_room} = Rooms.add(operator, "Other room", :public)
    other_room_key = other_room_identity |> Identity.pub_key()

    ChangeTracker.await()

    FunctionalityDynamicSupervisor
    |> DynamicSupervisor.start_child({CargoSyncSupervisor, [nil]})

    :timer.sleep(500)

    DynamicSupervisor.terminate_child(
      FunctionalityDynamicSupervisor,
      CargoSyncSupervisor |> Process.whereis()
    )

    users_count = length(User.list())

    path = [@mount_path, "cargo_db", Chat.Db.version_path()] |> Path.join()
    start_supervised!({MediaDbSupervisor, [CargoDb, path]})

    Switching.set_default(CargoDb)

    refute length(User.list()) == users_count
    refute Rooms.get(cargo_room_key)
    refute Rooms.get(other_room_key)
  end
end
