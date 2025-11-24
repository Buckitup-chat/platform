# Change: Add Postgres-level Internal→Main synchronization via ElectricSQL

## Why
The platform currently performs copy/mirror operations between internal and main repositories. We need local, in-process Postgres-level synchronization from InternalDb (SD card) to MainDb (USB) using ElectricSQL (part of Chat), executed entirely on-device with no network.

## What Changes
- Introduce a one-way, local synchronization pipeline InternalDb → MainDb at the Postgres level using ElectricSQL, invoked as function calls.
- Run the sync inside `Platform.Storage.InternalToMain.Copier` lifecycle: start right after bootstrap copy and finish with the copier stage.
- Expose minimal sync status via logging/telemetry; status flips to done when copier completes.
- Initial scope is the `users` schema (configurable to expand later).
- Delegate ElectricSQL in-process sync API to Chat (separate requirements file) using repo modules (no URLs/TLS).

## Impact
- Affected specs: storage-sync
- Affected code: Platform.Storage.InternalToMain (Switcher/Copier), Platform.Storage.Logic, supervision tree for storage/sync, configuration.
- External dependency: ElectricSQL (via Chat) used locally in-process.
