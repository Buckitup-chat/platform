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

## OpenSpec (spec-driven change workflow)

- [`openspec/AGENTS.md`](../openspec/AGENTS.md) — authoritative workflow
- [`openspec/project.md`](../openspec/project.md) — project conventions
- [`openspec/specs/`](../openspec/specs/) — active specs
- [`openspec/changes/`](../openspec/changes/) — in-flight and archived change proposals

## Tooling

- [`../CLAUDE.md`](../CLAUDE.md) — Claude Code guidance
- [`../AGENTS.md`](../AGENTS.md) — OpenSpec bootstrap
- [`../STYLE.md`](../STYLE.md) — code style
- [`../.windsurf/workflows/`](../.windsurf/workflows/) — Windsurf editor workflows
