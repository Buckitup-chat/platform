import Config

config :chat, :cub_db_file, "priv/test_db"
config :chat, :admin_cub_db_file, "priv/test_admin_db"

config :chat,
  files_base_dir: "priv/test_db/files",
  write_budget: 100_000_000,
  writable: :yes

config :chat, ChatWeb.Endpoint, pubsub_server: Chat.PubSub
