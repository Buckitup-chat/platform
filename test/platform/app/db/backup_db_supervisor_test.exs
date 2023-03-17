defmodule Platform.App.Db.BackupDbSupervisorTest do
  use ExUnit.Case, async: false

  alias Chat.Content.Files
  alias Chat.Utils.StorageId

  alias Chat.{
    ChunkedFiles,
    FileIndex,
    Messages,
    Rooms,
    User
  }

  alias Chat.Db.{BackupDb, ChangeTracker, InternalDb, MainDb, Switching}
  alias Platform.App.Db.{BackupDbSupervisor, MainDbSupervisor}
  alias Platform.App.Media.FunctionalityDynamicSupervisor
  alias Support.FakeData

  setup do
    on_exit(fn ->
      Switching.set_default(InternalDb)
    end)
  end

  describe "sync" do
    test "mirrors changes made to main to internal and backup DBs" do
      DynamicSupervisor.start_link(name: Platform.MainDbSupervisor, strategy: :one_for_one)

      Platform.MainDbSupervisor
      |> DynamicSupervisor.start_child({MainDbSupervisor, [nil]})

      :timer.sleep(5000)

      DynamicSupervisor.start_link(name: FunctionalityDynamicSupervisor, strategy: :one_for_one)

      FunctionalityDynamicSupervisor
      |> DynamicSupervisor.start_child({BackupDbSupervisor, [nil]})

      :timer.sleep(5000)

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

      DynamicSupervisor.terminate_child(
        FunctionalityDynamicSupervisor,
        BackupDbSupervisor |> Process.whereis()
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

      ["priv/test_storage", "main_db", Chat.Db.version_path()]
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

      path =
        ["priv/test_media", "main_db", Chat.Db.version_path()]
        |> Path.join()

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
