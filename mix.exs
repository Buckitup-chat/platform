defmodule Platform.MixProject do
  use Mix.Project

  @app :platform
  @version "0.4.0"
  @all_targets [:rpi4, :buckitup_rpi4]

  def project do
    [
      app: @app,
      version: @version,
      elixir: "~> 1.19",
      archives: [nerves_bootstrap: "~> 1.14"],
      listeners: listeners(Mix.target(), Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      releases: [{@app, release()}]
    ]
    |> more_project()
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger, :runtime_tools],
      mod: {Platform.Application, []}
    ]
  end

  def cli do
    [preferred_targets: [run: :host, test: :host]]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      # Dependencies for all targets
      {:nerves, "~> 1.10", runtime: false},
      {:shoehorn, "~> 0.9.1"},
      {:ring_logger, "~> 0.11.0"},
      {:toolshed, "~> 0.4.0"},

      # Allow Nerves.Runtime on host to support development, testing and CI.
      # See config/host.exs for usage.
      {:nerves_runtime, "~> 0.13.0"},

      # Dependencies for all targets except :host
      {:nerves_pack, "~> 0.7.1", targets: @all_targets},

      # Dependencies for specific targets
      # NOTE: It's generally low risk and recommended to follow minor version
      # bumps to Nerves systems. Since these include Linux kernel and Erlang
      # version updates, please review their release notes in case
      # changes to your application are needed.
      {:nerves_system_rpi4, "~> 1.24", runtime: false, targets: :rpi4}
    ]
    |> more_deps()
  end

  def release do
    [
      overwrite: true,
      # Erlang distribution is not started automatically.
      # See https://hexdocs.pm/nerves_pack/readme.html#erlang-distribution
      cookie: "#{@app}_cookie",
      include_erts: &Nerves.Release.erts/0,
      steps: [&Nerves.Release.init/1, :assemble],
      strip_beams: Mix.env() == :prod or [keep: ["Docs"]]
    ]
    |> more_release()
  end

  # Uncomment the following line if using Phoenix > 1.8.
  # defp listeners(:host, :dev), do: [Phoenix.CodeReloader]
  defp listeners(_, _), do: []

  ################################
  defp more_project(project) do
    Keyword.merge(project,
      elixirc_paths: elixirc_paths(Mix.env()),
      preferred_cli_env: [
        coveralls: :test,
        "coveralls.detail": :test,
        "coveralls.html": :test
      ],
      preferred_cli_target: [run: :host, test: :host],
      test_coverage: [tool: ExCoveralls]
    )
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp more_deps(deps) do
    deps ++
      [
        {:ramoops_logger, "~> 0.3.0"},
        {:observer_cli, "~> 1.8"},
        {:nerves_leds, "~> 0.8.1"},
        # pg_query_ex is needed for ElectricSync patched to recompile correctly
        {:pg_query_ex, path: "../pg_query", override: true},
        {:dns, "~> 2.4"},
        {:socket, "~> 0.3.13"},
        {:postgrex, "~> 0.17"},
        {:ecto, "~> 3.7"},
        {:excoveralls, "~> 0.14", only: [:test]},
        {:graceful_genserver, "~> 0.1.0"},
        {:circuits_uart, "~> 1.3"},
        {:circuits_gpio, "~> 2.0 or ~> 1.0"},
        {:muontrap, "~> 1.0"},
        {:req, "~> 0.5"},
        ### project deps
        {:toolbox, path: "../toolbox", targets: [:host | @all_targets]},
        {:chat,
         path: "../chat",
         targets: [:host | @all_targets],
         env: if(Mix.target() == :host, do: Mix.env(), else: :prod)},
        # Buckitup customized image
        {:buckitup_rpi4,
         github: "Buckitup-chat/buckitup_rpi4", runtime: false, targets: :buckitup_rpi4}
        # {:buckitup_rpi4,
        #  path: "../fresh/buckitup_rpi4",
        #  runtime: false,
        #  targets: :buckitup_rpi4,
        #  nerves: [compile: true]}
      ]
  end

  defp more_release(release) do
    Keyword.merge(release,
      version: build_version()
    )
  end

  defp build_version do
    {platform_hash, 0} = System.cmd("git", ~w|log -1 --date=format:%Y-%m-%d --format=%cd_%h|)
    {chat_hash, 0} = System.cmd("bash", ["chat_version.sh"])

    [platform_hash, chat_hash]
    |> Enum.map_join("___", &String.trim/1)
  end
end
