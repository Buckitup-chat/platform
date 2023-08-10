# This file is responsible for configuring your application and its
# dependencies.
#
# This configuration file is loaded before any dependency and is restricted to
# this project.
import Config

# Enable the Nerves integration with Mix
Application.start(:nerves_bootstrap)

config :platform,
  env: Mix.env(),
  mount_path_media: "/root/media",
  mount_path_storage: "/root/storage",
  target: Mix.target()

# Customize non-Elixir parts of the firmware. See
# https://hexdocs.pm/nerves/advanced-configuration.html for details.

config :nerves, :firmware, rootfs_overlay: "rootfs_overlay"

# Set the SOURCE_DATE_EPOCH date for reproducible builds.
# See https://reproducible-builds.org/docs/source-date-epoch/ for more information

config :nerves, source_date_epoch: "1644342070"

# Use Ringlogger as the logger backend and remove :console.
# See https://hexdocs.pm/ring_logger/readme.html for more information on
# configuring ring_logger.

config :tzdata, :autoupdate, :disabled
config :elixir, :time_zone_database, Tzdata.TimeZoneDatabase
config :phoenix, :json_library, Jason

config :chat, file_chunk_size: 10 * 1024 * 1024
config :chat, Chat.Db.ChangeTracker, expire_seconds: 31

config :mime, :types, %{
  "text/plain" => ["social_part", "data"]
}

# Uncomment the following line to enable db writing logging
config :chat, :copying_logging, true


if Mix.target() == :host or Mix.target() == :"" do
  import_config "host.exs"
else
  import_config "target.exs"
end
