import Config

config :chat, :admin_cub_db_file, "priv/test_admin_db"

# Internal CubDB stays at priv/test_db/v.10.1
config :chat, Chat.Storage,
  internal_root: "priv",
  internal_dir: "test_db",
  media_root: "priv/test_media"

config :chat,
  files_base_dir: "priv/test_db/files",
  write_budget: 100_000_000,
  writable: :yes

config :chat, ChatWeb.Endpoint, pubsub_server: Chat.PubSub

config :platform,
  mount_path_media: "priv/test_media",
  mount_path_storage: "priv/test_storage"

config :chat, Chat.Db.ChangeTracker, expire_seconds: 3

# At :debug the Ecto query flood pushes Logger into sync mode, where
# AdminLogger's CubDB writes can wedge every logging process.
# :info, not :warning - some tests assert on info logs.
config :logger, level: :info

# Drive repos on host derive their database names from this one
# (platform_test_chat_<device>), keeping tests off the dev "chat" databases.
config :chat, Chat.Repo,
  database: "platform_test_chat",
  password: System.get_env("POSTGRES_PASSWORD", "postgres")

# Test repositories for integration testing
config :platform, Platform.Test.InternalRepo,
  database: "platform_test_internal",
  username: System.get_env("POSTGRES_USER", "postgres"),
  password: System.get_env("POSTGRES_PASSWORD", "postgres"),
  hostname: System.get_env("POSTGRES_HOST", "localhost"),
  port: String.to_integer(System.get_env("POSTGRES_PORT", "5432")),
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: 10

config :platform, Platform.Test.MainRepo,
  database: "platform_test_main",
  username: System.get_env("POSTGRES_USER", "postgres"),
  password: System.get_env("POSTGRES_PASSWORD", "postgres"),
  hostname: System.get_env("POSTGRES_HOST", "localhost"),
  port: String.to_integer(System.get_env("POSTGRES_PORT", "5432")),
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: 10

config :platform, :ecto_repos, [Platform.Test.InternalRepo, Platform.Test.MainRepo]
