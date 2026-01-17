import Config

config :platform,
  env: Mix.env(),
  mount_path_media: "/root/media",
  target: Mix.target()

config :tzdata, :autoupdate, :disabled
config :elixir, :time_zone_database, Tzdata.TimeZoneDatabase
config :phoenix, :json_library, Jason

config :chat, file_chunk_size: 10 * 1024 * 1024
config :chat, Chat.Db.ChangeTracker, expire_seconds: 31

config :chat,
  topic_to_platform: "chat->platform",
  topic_from_platform: "platform->chat",
  topic_to_zerotier: "-> zerotier"

config :mime, :types, %{
  "text/plain" => ["social_part", "data"],
  "application/zip" => ["fw"]
}

# Uncomment the following line to enable db writing logging
config :chat, :db_write_logging, true

# PostgreSQL synchronization configuration
config :platform, Platform.Storage.Sync, schemas: [:users]

# PostgreSQL configuration
config :chat,
  pg_port: 5432,
  pg_socket_dir: "/tmp/pg_run"

# Configure PostgreSQL connection for Chat.Repo
config :chat, Chat.Repo,
  adapter: Ecto.Adapters.Postgres,
  username: "postgres",
  password: "",
  database: "chat",
  hostname: "localhost",
  port: 5432,
  pool_size: 5,
  show_sensitive_data_on_connection_error: false

# Configure Ecto repos
config :chat, ecto_repos: [Chat.Repo]

config :phoenix_sync,
  env: config_env(),
  mode: :embedded,
  repo: Chat.Repo,
  storage_dir: "/root/electric"

if Mix.target() == :host or Mix.target() == :"" do
  import_config "host.exs"
else
  import_config "target.exs"
end
