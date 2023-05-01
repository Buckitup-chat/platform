defmodule Platform.App.Db.BackupDbSupervisorTest do
  use ExUnit.Case, async: false

  import Support.RetryHelper

  alias Chat.{AdminRoom, ChunkedFiles, FileIndex, Messages, Rooms, User}
  alias Chat.Admin.{BackupSettings, MediaSettings}
  alias Chat.Content.Files
  alias Chat.Db.{BackupDb, Common, ChangeTracker, InternalDb, MainDb, Switching}
  alias Chat.Utils.StorageId
  alias Platform.App.Db.{BackupDbSupervisor, MainDbSupervisor}
  alias Support.FakeData

  @media_mount_path Application.compile_env(:platform, :mount_path_media)
  @storage_mount_path Application.compile_env(:platform, :mount_path_storage)

  setup do
    [@storage_mount_path, "main_db"]
    |> Path.join()
    |> File.rm_rf!()

    "#{@media_mount_path}/**/*"
    |> Path.wildcard()
    |> Enum.reject(&String.contains?(&1, "DCIM"))
    |> Enum.each(&File.rm_rf!/1)

    AdminRoom.store_media_settings(%MediaSettings{functionality: :backup})

    start_supervised!(
      {DynamicSupervisor, name: Platform.MainDbSupervisor, strategy: :one_for_one}
    )

    start_supervised!(
      {DynamicSupervisor, name: Platform.App.Media.DynamicSupervisor, strategy: :one_for_one}
    )

    on_exit(fn ->
      Switching.set_default(InternalDb)
    end)
  end

  describe "regular backup" do
    test "copies data once from main to backup DB and vice versa" do
      AdminRoom.store_backup_settings(%BackupSettings{type: :regular})

      Platform.MainDbSupervisor
      |> DynamicSupervisor.start_child({MainDbSupervisor, [nil]})

      retry_until(5_000, fn ->
        assert Common.get_chat_db_env(:mode) == :main
      end)

      charlie = User.login("Charlie")
      User.register(charlie)

      {room_identity, room} = Rooms.add(charlie, "Charlie's room", :request)

      %Messages.File{data: image_data} = image = FakeData.image("1.pp")
      [file_key, encoded_chunk_secret, _, _, _, _] = image_data
      chunk_secret = Base.decode64!(encoded_chunk_secret)

      {message_index, message} =
        image
        |> Map.put(:timestamp, 4)
        |> Rooms.add_new_message(charlie, room.pub_key)

      FileIndex.save(
        file_key,
        room.pub_key,
        message.id,
        chunk_secret
      )

      _file_secret = ChunkedFiles.new_upload(file_key)
      ChunkedFiles.save_upload_chunk(file_key, {0, 17}, 30, "some part of info ")
      ChangeTracker.await({:file_chunk, file_key, 0, 17})
      ChunkedFiles.save_upload_chunk(file_key, {18, 29}, 30, "another part")

      ChangeTracker.await()

      assert {:ok, _pid} =
               Platform.App.Media.DynamicSupervisor
               |> DynamicSupervisor.start_child({Platform.App.Media.Supervisor, [nil]})

      assert ProcessHelper.process_not_running(BackupDbSupervisor)

      path = [@media_mount_path, "backup_db", Chat.Db.version_path()] |> Path.join()
      Chat.Db.MediaDbSupervisor.start_link([BackupDb, path])

      Switching.set_default(BackupDb)

      assert [^file_key, ^encoded_chunk_secret, _, _, _, _] =
               Rooms.read_message(
                 {message_index, message.id},
                 room_identity
               )
               |> Map.get(:content)
               |> StorageId.from_json()
               |> Files.get()
    end
  end

  describe "continuous backup" do
    test "mirrors main DB changes to internal and backup DBs" do
      AdminRoom.store_backup_settings(%BackupSettings{type: :continuous})

      DynamicSupervisor.start_link(name: Platform.MainDbSupervisor, strategy: :one_for_one)

      Platform.MainDbSupervisor
      |> DynamicSupervisor.start_child({MainDbSupervisor, [nil]})

      retry_until(5_000, fn ->
        assert Common.get_chat_db_env(:mode) == :main
      end)

      assert {:ok, _pid} =
               Platform.App.Media.DynamicSupervisor
               |> DynamicSupervisor.start_child({Platform.App.Media.Supervisor, [nil]})

      retry_until(5_000, fn ->
        assert backup: false in Common.get_chat_db_env(:flags)
      end)

      charlie = User.login("Charlie")
      User.register(charlie)

      {room_identity, room} = Rooms.add(charlie, "Charlie's room", :request)

      %Messages.File{data: image_data} = image = FakeData.image("1.pp")
      [file_key, encoded_chunk_secret, _, _, _, _] = image_data
      chunk_secret = Base.decode64!(encoded_chunk_secret)

      {message_index, message} =
        image
        |> Map.put(:timestamp, 4)
        |> Rooms.add_new_message(charlie, room.pub_key)

      FileIndex.save(
        file_key,
        room.pub_key,
        message.id,
        chunk_secret
      )

      file_secret = ChunkedFiles.new_upload(file_key)
      ChunkedFiles.save_upload_chunk(file_key, {0, 17}, 30, "some part of info ")
      ChangeTracker.await({:file_chunk, file_key, 0, 17})
      ChunkedFiles.save_upload_chunk(file_key, {18, 29}, 30, "another part")

      ChangeTracker.await()

      :timer.sleep(200)
      assert Process.whereis(BackupDbSupervisor)

      DynamicSupervisor.terminate_child(
        Platform.App.Media.DynamicSupervisor,
        Platform.App.Media.Supervisor |> Process.whereis()
      )

      DynamicSupervisor.terminate_child(
        Platform.MainDbSupervisor,
        MainDbSupervisor |> Process.whereis()
      )

      assert [^file_key, ^encoded_chunk_secret, _, _, _, _] =
               Rooms.read_message(
                 {message_index, message.id},
                 room_identity
               )
               |> Map.get(:content)
               |> StorageId.from_json()
               |> Files.get()

      assert ChunkedFiles.read({file_key, file_secret}) ==
               "some part of info another part"

      [@storage_mount_path, "main_db", Chat.Db.version_path()]
      |> Path.join()
      |> Chat.Db.MainDbSupervisor.start_link()

      Switching.set_default(MainDb)

      assert [^file_key, ^encoded_chunk_secret, _, _, _, _] =
               Rooms.read_message(
                 {message_index, message.id},
                 room_identity
               )
               |> Map.get(:content)
               |> StorageId.from_json()
               |> Files.get()

      assert ChunkedFiles.read({file_key, file_secret}) ==
               "some part of info another part"

      path = [@media_mount_path, "backup_db", Chat.Db.version_path()] |> Path.join()
      Chat.Db.MediaDbSupervisor.start_link([BackupDb, path])

      Switching.set_default(BackupDb)

      assert [^file_key, ^encoded_chunk_secret, _, _, _, _] =
               Rooms.read_message(
                 {message_index, message.id},
                 room_identity
               )
               |> Map.get(:content)
               |> StorageId.from_json()
               |> Files.get()
    end
  end
end
