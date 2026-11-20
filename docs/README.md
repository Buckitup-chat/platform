# Platform Documentation

## Architecture & Lifecycle

- [PostgreSQL lifecycle](./pg_lifecycle.md) — init, supervision tree, staged startup, replication between internal and per-drive PostgreSQL instances

## Requirements

- [PostgreSQL management](./reqs/postgresql-management.md) — components, supervision trees, responsibilities

## Ideas / Proposals

- [Future ideas](./future_ideas.md) — sketches not yet scheduled

## Co-located module docs

READMEs live next to the code they describe:

- [`lib/platform/app/sync`](../lib/platform/app/sync/README.md)
- [`lib/platform/sensor`](../lib/platform/sensor/README.md)
- [`lib/platform/tools`](../lib/platform/tools/README.md) · [firmware tool list](../lib/platform/tools/FW_TOOLS.list.md)
- [`lib/platform/usb_drives`](../lib/platform/usb_drives/README.md)

## Tooling

- [`../CLAUDE.md`](../CLAUDE.md) — Claude Code guidance
- [`../STYLE.md`](../STYLE.md) — code style
- [`../.windsurf/workflows/`](../.windsurf/workflows/) — Windsurf editor workflows
