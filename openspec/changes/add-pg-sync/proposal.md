# Change: Add PostgreSQL-level synchronization mechanics

## Why
The platform currently uses CubDB for data synchronization between internal (SD card) and main (USB drive) databases. As we migrate to PostgreSQL for user data storage, we need equivalent synchronization mechanics at the PostgreSQL level that preserve the same behavioral guarantees and mode-based state machine while using PostgreSQL-native replication features.

## What Changes
- Implement row-level diff+copy synchronization for PostgreSQL databases (never drop/recreate databases)
- Add PostgreSQL logical replication for ongoing change streaming
- Create `Platform.Storage.Pg.LogicalReplicator` module for publication/subscription management
- Enhance `Platform.Storage.Sync.run_local_sync/1` to perform actual row-level reconciliation
- Integrate PG sync into existing `InternalToMain.Copier` and `MainReplicator` workflows
- Maintain existing mode-based state machine (`:internal`, `:internal_to_main`, `:main`, `:main_to_internal`)
- Support configurable schema list (starting with `:users`, expandable later)

## Impact
- **Affected specs**: `storage-sync` (new requirements)
- **Affected code**:
  - `Platform.Storage.Sync` - implement actual diff+copy logic
  - `Platform.Storage.Pg.LogicalReplicator` - new module for logical replication
  - `Platform.Storage.InternalToMain.Copier` - integrate PG sync after CubDB copy
  - `Platform.Storage.Logic` - add PG replication alongside CubDB replication
  - `Platform.Storage.MainReplicator` - trigger PG replication health checks
- **Breaking changes**: None - PG sync runs alongside existing CubDB sync until CubDB is retired
- **Dependencies**: Requires PostgreSQL 10+ with logical replication support
