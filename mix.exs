defmodule Platform.MixProject do
  use Mix.Project

  @app :platform
  @version "0.1.2"
  # @all_targets [:rpi, :rpi0, :rpi2, :rpi3, :rpi3a, :rpi4, :bbb, :osd32mp1, :x86_64]
  @all_targets [:rpi3, :rpi3a, :rpi4, :bktp_rpi4]

  def project do
    [
      app: @app,
      version: @version,
      elixir: "~> 1.14",
      elixirc_paths: elixirc_paths(Mix.env()),
      archives: [nerves_bootstrap: "~> 1.10"],
      start_permanent: Mix.target() != :host,
      build_embedded: true,
      deps: deps(),
      releases: [{@app, release()}],
      preferred_cli_env: [
        coveralls: :test,
        "coveralls.detail": :test,
        "coveralls.html": :test
      ],
      preferred_cli_target: [run: :host, test: :host],
      test_coverage: [tool: ExCoveralls]
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      mod: {Platform.Application, []},
      extra_applications: [:logger, :runtime_tools, :inets, :crypto]
    ]
  end

  # Specifies which paths to compile per environment.
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:ramoops_logger, "~> 0.3.0"},
      {:observer_cli, "~> 1.7"},
      {:nerves_leds, "~> 0.8.1"},
      {:dns, "~> 2.3"},
      # Dependencies for all targets
      {:nerves, "~> 1.9.1", runtime: false},
      {:shoehorn, "~> 0.7.0"},
      {:ring_logger, "~> 0.8.1"},
      {:toolshed, "~> 0.2.13"},

      # Dependencies for all targets except :host
      {:nerves_runtime, "~> 0.11.3", targets: @all_targets},
      {:nerves_pack, "~> 0.6.0", targets: @all_targets},
      # {:chat, path: "../chat", targets: @all_targets, env: Mix.env()},
      # {:dns, "~> 2.3", targets: @all_targets},

      # Dependencies for specific targets
      # NOTE: It's generally low risk and recommended to follow minor version
      # bumps to Nerves systems. Since these include Linux kernel and Erlang
      # version updates, please review their release notes in case
      # changes to your application are needed.
      {:nerves_system_rpi, "~> 1.21", runtime: false, targets: :rpi},
      {:nerves_system_rpi0, "~> 1.21", runtime: false, targets: :rpi0},
      {:nerves_system_rpi2, "~> 1.21", runtime: false, targets: :rpi2},
      {:nerves_system_rpi3, "~> 1.21", runtime: false, targets: :rpi3},
      {:nerves_system_rpi3a, "~> 1.21", runtime: false, targets: :rpi3a},
      {:nerves_system_rpi4, "~> 1.21", runtime: false, targets: :rpi4},
      {:nerves_system_bbb, "~> 2.12", runtime: false, targets: :bbb},
      {:nerves_system_osd32mp1, "~> 0.8", runtime: false, targets: :osd32mp1},
      {:nerves_system_x86_64, "~> 1.21", runtime: false, targets: :x86_64},
      {:bktp_rpi4,
       github: "Buckitup-chat/bktp_rpi4",
       runtime: false,
       targets: :bktp_rpi4,
       nerves: [compile: false]},
      # {:bktp_rpi4,
      #  path: "../bktp_rpi4", runtime: false, targets: :bktp_rpi4, nerves: [compile: true]},
      {:chat,
       path: "../chat",
       targets: [:host | @all_targets],
       env: if(Mix.target() == :host, do: Mix.env(), else: :prod)},
      # {:chat, path: "../chat", env: Mix.env()},
      {:excoveralls, "~> 0.14", only: [:test]},
      {:graceful_genserver, "~> 0.1.0"},
      {:circuits_uart, "~> 1.3"},
      {:circuits_gpio, "~> 1.0"}
    ]
  end

  def release do
    [
      overwrite: true,
      # Erlang distribution is not started automatically.
      # See https://hexdocs.pm/nerves_pack/readme.html#erlang-distribution
      cookie: "#{@app}_cookie",
      include_erts: &Nerves.Release.erts/0,
      steps: [&Nerves.Release.init/1, :assemble],
      strip_beams: Mix.env() == :prod or [keep: ["Docs"]],
      version: build_version()
    ]
  end

  defp build_version do
    {platform_hash, 0} = System.cmd("git", ~w|log -1 --date=format:%Y-%m-%d --format=%cd_%h|)
    {chat_hash, 0} = System.cmd("bash", ["chat_version.sh"])

    [platform_hash, chat_hash]
    |> Enum.map_join("___", &String.trim/1)
  end
end
