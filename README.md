# Platform

Nerves-based embedded Elixir firmware for Raspberry Pi devices (rpi3, rpi3a, rpi4, bktp_rpi4). Manages USB storage, per-drive PostgreSQL instances, and hosts the companion `chat` application on-device.

## Documentation

See [docs/README.md](./docs/README.md) for the full index.

Quick links:
- [PostgreSQL lifecycle](./docs/pg_lifecycle.md) — initialization, supervision, replication
- [PostgreSQL management requirements](./docs/reqs/postgresql-management.md)
- [Future ideas](./docs/future_ideas.md)
- [OpenSpec workflow](./openspec/AGENTS.md) — spec-driven change process
- [Style guide](./STYLE.md)

Module-level docs live next to the code:
- [app/sync](./lib/platform/app/sync/README.md)
- [sensor](./lib/platform/sensor/README.md)
- [tools](./lib/platform/tools/README.md) · [firmware tool list](./lib/platform/tools/FW_TOOLS.list.md)
- [usb_drives](./lib/platform/usb_drives/README.md)

## Targets

Nerves applications produce images for hardware targets based on the
`MIX_TARGET` environment variable. If `MIX_TARGET` is unset, `mix` builds an
image that runs on the host (e.g., your laptop). This is useful for executing
logic tests, running utilities, and debugging. Other targets are represented by
a short name like `rpi3` that maps to a Nerves system image for that platform.
All of this logic is in the generated `mix.exs` and may be customized. For more
information about targets see:

https://hexdocs.pm/nerves/supported-targets.html

## Getting Started

To start your Nerves app:
  * `export MIX_TARGET=my_target` or prefix every command with
    `MIX_TARGET=my_target`. For example, `MIX_TARGET=rpi3`
  * Install dependencies with `mix deps.get`
  * Create firmware with `mix firmware`
  * Burn to an SD card with `mix burn`

## Learn more

  * Official docs: https://hexdocs.pm/nerves/getting-started.html
  * Official website: https://nerves-project.org/
  * Forum: https://elixirforum.com/c/nerves-forum
  * Elixir Slack #nerves channel: https://elixir-slack.community/
  * Elixir Discord #nerves channel: https://discord.gg/elixir
  * Source: https://github.com/nerves-project/nerves
