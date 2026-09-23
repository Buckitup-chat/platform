# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is a Nerves-based embedded Elixir platform that runs on Raspberry Pi devices (rpi3, rpi3a, rpi4, bktp_rpi4). It manages USB storage devices, PostgreSQL databases, and integrates with a companion `chat` application via PubSub messaging.

## Build Commands

```bash
# Run tests
make test                           # or: MIX_TARGET=host MIX_ENV=test mix test
MIX_TARGET=host MIX_ENV=test mix test test/path/to/test.exs  # single test file
MIX_TARGET=host MIX_ENV=test mix test test/path/to/test.exs:42  # specific line

# Compile with warnings as errors
make check

# Build firmware for target device
export MIX_TARGET=bktp_rpi4         # or rpi3, rpi3a, rpi4
mix deps.get
mix firmware

# Upload firmware to device via network
mix upload

# Burn firmware to SD card
mix firmware.burn

# Full build + upload + ssh to device
make burn_in

# Generate coverage report
make cover
```

## Architecture

### Application Startup

`Platform.Application` starts different supervision trees based on target:
- **Host mode**: Runs emulated versions for local development/testing
- **Target mode**: Full hardware integration with networking, DNS, PostgreSQL, ZeroTier

### Key Supervision Hierarchies

**Platform.App.DeviceSupervisor**: Top-level supervisor for USB drive handling
- Manages `Platform.Drives` DynamicSupervisor
- Spawns `Platform.App.Drive.BootSupervisor` per detected USB drive

**Platform.App.DatabaseSupervisor**: Staged startup for the internal PostgreSQL instance (chat DB on device). Mirrors `BootSupervisor`'s pattern with compile-time host/target module selection.

**Platform.App.Drive.MainDbSupervisor / BackupDbSupervisor**: Per-drive supervisors for main and backup USB drives respectively. `MainDbSupervisor` handles internal→main replication and Phoenix.Sync init. `BackupDbSupervisor` handles backup copying.

**Platform.App.Drive.BootSupervisor**: Per-drive staged startup sequence
- Healer → Mounter → PostgreSQL initialization → DB creation → Repo → Migrations → Decider
- Uses compile-time module selection: real modules on target, emulators on host

**Platform.Storage.BootWatchdog**: Monitors staged boot trees from outside. Fingerprints each tree every 30s; if a stage stalls (alive but wedged), kills the deepest stuck stage so supervisors can recover. Watches internal DB tree and each drive tree up to `Decider`.

### Staged Supervision Pattern

The `Platform` module provides helpers for building staged supervision trees:
- `{:stage, name, spec}`: Start stage supervisor, then child
- `{:step, name, spec}`: Start child, then stage supervisor
- `prepare_stages/2`: Builds nested supervision tree from spec list

### Device Identity

`Platform.DeviceId` reads the RPi hardware serial from `/proc/cpuinfo` to produce a stable device ID (e.g. `RPi4_<serial>`). Implements the `Chat.DeviceId` behaviour — on host/server the fallback `Chat.DeviceId.Default` uses HTTPS domain or MAC address. Device IDs anchor vouch token scopes (`device.<id>.*`).

### Inter-App Communication

`Platform.ChatBridge.Worker` communicates with the `chat` app via Phoenix PubSub:
- Listens on `chat->platform` topic
- Responds on `platform->chat` topic
- Handles: WiFi settings, LAN configuration, firmware upgrades, sensor connections

### Storage/Database Layer

- **USB drive detection**: `Platform.UsbDrives.Detector` watches for device insert/eject
- **PostgreSQL**: Per-drive instances with port = 5432 + (device letter - 'a' + 1)
- **Replication**: `Platform.Storage.Logic` handles main→internal DB replication
- **Logical replication**: `Platform.Tools.Postgres.LogicalReplicator` for PostgreSQL streaming

### Target vs Host Modules

Compile-time switches in `BootSupervisor`:
| Target Module | Host Emulator |
|--------------|---------------|
| `Platform.Storage.Healer` | `Platform.Emulator.Drive.Healer` |
| `Platform.Storage.Mounter` | `Platform.Emulator.Drive.Mounter` |
| `Platform.Storage.Pg.*` | `Platform.Emulator.EmptyBypass` |

## Dependencies

External dependency at sibling directory:
- `../chat` - Chat application (required)
- `../pg_query` - PostgreSQL query parser (required)
- `../bktp_rpi4` - Custom Nerves system (for bktp_rpi4 target)

## Testing

Tests require PostgreSQL running locally. Test setup:
- Creates test databases via `Platform.Test.DatabaseHelper`
- Uses Ecto sandbox mode for isolation
- Test repos: `Platform.Test.InternalRepo`, `Platform.Test.MainRepo`

Integration tests are in files matching `*_integration_test.exs`.
