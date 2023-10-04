File.rm_rf("priv/test_admin_db")
File.rm_rf("priv/test_db")

"priv/test_media/**/*"
|> Path.wildcard()
|> Enum.reject(&String.contains?(&1, "DCIM"))
|> Enum.each(&File.rm_rf/1)

File.rm_rf("priv/test_storage")
ExUnit.start()
