import Config

# Use shoehorn to start the main application. See the shoehorn
# docs for separating out critical OTP applications such as those
# involved with firmware updates.

config :shoehorn,
  init: [:nerves_runtime, :nerves_pack],
  app: Mix.Project.config()[:app]

# Nerves Runtime can enumerate hardware devices and send notifications via
# SystemRegistry. This slows down startup and not many programs make use of
# this feature.

# config :nerves_runtime, :kernel, use_system_registry: false

# Erlinit can be configured without a rootfs_overlay. See
# https://github.com/nerves-project/erlinit/ for more information on
# configuring erlinit.

config :nerves,
  erlinit: [
    hostname_pattern: "nerves-%s"
  ]

# Configure the device for SSH IEx prompt access and firmware updates
#
# * See https://hexdocs.pm/nerves_ssh/readme.html for general SSH configuration
# * See https://hexdocs.pm/ssh_subsystem_fwup/readme.html for firmware updates

keys =
  [
    Path.join([System.user_home!(), ".ssh", "buckit.id_rsa.pub"]),
    Path.join([System.user_home!(), ".ssh", "id_rsa.pub"]),
    Path.join([System.user_home!(), ".ssh", "id_ecdsa.pub"]),
    Path.join([System.user_home!(), ".ssh", "id_ed25519.pub"])
  ]
  |> Enum.filter(&File.exists?/1)

if keys == [],
  do:
    Mix.raise("""
    No SSH public keys found in ~/.ssh. An ssh authorized key is needed to
    log into the Nerves device and update firmware on it using ssh.
    See your project's config.exs for this error message.
    """)

config :nerves_ssh,
  authorized_keys: Enum.map(keys, &File.read!/1)

#############################
##
## SSL or HTTP-only
##
#############################
domain =
  cond do
    domain = System.get_env("DOMAIN") -> domain
    true -> "demo.buckitup.org"
  end

domain_to_file_prefix = fn domain ->
  String.replace(domain, ".", "_")
end

chat_vsn = Application.spec(:chat, :vsn) |> to_string
cert_src_dir = "../cert/#{domain}"
cert_deploy_dir = "../chat/priv/certs"
cert_image_dir = "../chat-#{chat_vsn}/priv/certs"
File.rm_rf!(cert_deploy_dir)

ssl_cacertfile = "#{domain_to_file_prefix.(domain)}.ca-bundle"
ssl_certfile = "#{domain_to_file_prefix.(domain)}.crt"
ssl_keyfile = "priv.key"

cert_present? =
  [ssl_cacertfile, ssl_certfile, ssl_keyfile]
  |> Enum.map(&Path.join([cert_src_dir, &1]))
  |> Enum.all?(&File.exists?/1)

if cert_present? do
  File.mkdir_p!(cert_deploy_dir)

  [ssl_cacertfile, ssl_certfile, ssl_keyfile]
  |> Enum.map(fn filename ->
    File.cp!(Path.join([cert_src_dir, filename]), Path.join([cert_deploy_dir, filename]))
  end)

  config :chat, ChatWeb.Endpoint,
    url: [host: domain],
    http: [ip: {0, 0, 0, 0}, port: 80],
    https: [
      port: 443,
      cipher_suite: :strong,
      cacertfile: [cert_image_dir, ssl_cacertfile] |> Path.join(),
      certfile: [cert_image_dir, ssl_certfile] |> Path.join(),
      keyfile: [cert_image_dir, ssl_keyfile] |> Path.join()
    ],
    check_origin: ["//#{domain}"]
else
  config :chat, ChatWeb.Endpoint,
    http: [ip: {0, 0, 0, 0}, port: 80],
    url: [host: domain, scheme: "http"],
    check_origin: false
end

config :chat, :domain, domain

File.write!("built_for_domain", domain)

# maybe_usb =
#   if config_env() == :dev,
#     do: [{"usb0", %{type: VintageNetDirect}}],
#     else: []

# Configure the network using vintage_net
# See https://github.com/nerves-networking/vintage_net for more information
lan_as_dhcp_client = %{type: VintageNetEthernet, ipv4: %{method: :dhcp}}

lan_as_internet_replacement = %{
  type: VintageNetEthernet,
  dhcpd: %{
    start: {192, 168, 24, 10},
    end: {192, 168, 24, 250},
    options: %{
      dns: [{192, 168, 25, 1}],
      subnet: {255, 255, 255, 0},
      router: [{192, 168, 24, 1}],
      domain: domain,
      search: [domain]
    }
  },
  ipv4: %{
    address: {192, 168, 24, 1},
    method: :static,
    prefix_length: 24,
    name_servers: [{192, 168, 24, 1}]
  }
}

config :platform, :lan_profiles,
  internet: lan_as_dhcp_client,
  no_internet: lan_as_internet_replacement

config :vintage_net,
  regulatory_domain: "00",
  # Uncomment following to disable config change persistance. It need to be commented to allow wifi modification
  # persistence: VintageNet.Persistence.Null,
  internet_host_list: [{"192.168.25.1", 80}],
  additional_name_servers: [],
  config: [
    {"eth0", lan_as_internet_replacement},
    {"wlan0",
     %{
       type: VintageNetWiFi,
       dhcpd: %{
         start: {192, 168, 25, 10},
         end: {192, 168, 25, 250},
         options: %{
           dns: [{192, 168, 25, 1}],
           subnet: {255, 255, 255, 0},
           router: [{192, 168, 25, 1}],
           domain: domain,
           search: [domain]
         }
       },
       ipv4: %{
         address: {192, 168, 25, 1},
         method: :static,
         prefix_length: 24,
         name_servers: [{192, 168, 25, 1}]
       },
       vintage_net_wifi: %{
         networks: [
           %{
             key_mgmt: :wpa_psk,
             mode: :ap,
             psk: "buckitup",
             ssid: "BuckitUp.app",
             proto: "RSN",
             pairwise: "CCMP",
             group: "CCMP"
           }
         ]
       }
     }},
    {"usb0", %{type: VintageNetDirect}}
  ]

config :mdns_lite,
  # The `host` key specifies what hostnames mdns_lite advertises.  `:hostname`
  # advertises the device's hostname.local. For the official Nerves systems, this
  # is "nerves-<4 digit serial#>.local".  mdns_lite also advertises
  # "nerves.local" for convenience. If more than one Nerves device is on the
  # network, delete "nerves" from the list.

  host: [:hostname, "nerves"],
  ttl: 120,

  # Forbidding advertising services over wifi
  excluded_ifnames: ["eth0", "wlan0", "lo"],

  # Advertise the following services over mDNS.
  services: [
    # %{
    #   protocol: "ssh",
    #   transport: "tcp",
    #   port: 22
    # },
    # %{
    #   protocol: "sftp-ssh",
    #   transport: "tcp",
    #   port: 22
    # },
    # %{
    #   protocol: "epmd",
    #   transport: "tcp",
    #   port: 4369
    # }
  ]

# Chat endpoint config
config :chat, ChatWeb.Endpoint,
  render_errors: [view: ChatWeb.ErrorView, accepts: ~w(html json), layout: false],
  pubsub_server: Chat.PubSub,
  live_view: [signing_salt: "N+hZlbsm"],
  cache_static_manifest: "priv/static/cache_manifest.json",
  # Possibly not needed, but doesn't hurt
  # http: [port: {:system, "PORT"}],
  #  http: [port: 80],
  # url: [host: System.get_env("APP_NAME") <> ".gigalixirapp.com", port: 443]
  secret_key_base: "HEY05EB1dFVSu6KykKHuS4rQPQzSHv4F7mGVB/gnDLrIu75wE/ytBXy2TaL3A6RA",
  # secret_key_base: Map.fetch!(System.get_env(), "SECRET_KEY_BASE"),
  server: true,
  code_reloader: false

maybe_nerves_local =
  if config_env() == :dev,
    do: ["http://nerves.local"],
    else: []

config :chat, :cub_db_file, "/root/db"
config :chat, :admin_cub_db_file, "/root/admin_db_v2"

config :chat, :set_time, true

config :chat,
  data_pid: nil,
  files_base_dir: "/root/db/files",
  write_budget: 0,
  mode: :internal,
  flags: [],
  writable: :no

config :platform, :tmp_size, "1G"

config :logger,
  backends: [RamoopsLogger, RingLogger],
  compile_time_purge_matching: [
    [application: :ssl, level_lower_than: :error]
  ]

# config :phoenix, :json_library, Jason
# config :phoenix, :json_library, Poision

# Do not print debug messages in production

# Import target specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
# Uncomment to use target specific configurations

# import_config "#{Mix.target()}.exs"
