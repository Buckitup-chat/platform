File.rm_rf("priv/test_admin_db")
File.rm_rf("priv/test_db")

"priv/test_media/**/*"
|> Path.wildcard()
|> Enum.reject(&String.contains?(&1, "DCIM"))
|> Enum.each(&File.rm_rf/1)

File.rm_rf("priv/test_storage")

Logger.put_application_level(:graceful_genserver, :error)
Logger.put_application_level(:platform, :error)
Logger.put_application_level(:chat, :error)

# Setup test databases for integration tests
IO.puts("\n=== Setting up PostgreSQL integration test databases ===")
Platform.Test.DatabaseHelper.setup_databases()

# Cleanup on exit
System.at_exit(fn _status ->
  IO.puts("\n=== Cleaning up PostgreSQL integration test databases ===")
  Platform.Test.DatabaseHelper.teardown_databases()
end)

ExUnit.start()
