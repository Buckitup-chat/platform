import Config

config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

config :logger, level: :debug

config :chat,
  data_pid: nil,
  files_base_dir: "priv/db/files",
  write_budget: 1_000_000,
  mode: :internal,
  flags: [],
  writable: :yes

# Add configuration that is only needed when running on the host here.

if config_env() == :test do
  import_config "host.test.exs"
end
