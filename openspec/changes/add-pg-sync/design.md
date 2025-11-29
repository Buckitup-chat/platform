# Design: PostgreSQL-level Synchronization

## Context
The BuckitUp platform manages data across two PostgreSQL clusters:
- **Internal PG** on SD card (always present)
- **Main PG** on USB drive (present only when drive is plugged)

Currently, CubDB handles synchronization via `Chat.Db.Copying` and `Chat.Db.Switching`. As we migrate user data to PostgreSQL, we need equivalent sync mechanics that:
- Never drop/recreate databases (row-level reconciliation only)
- Support offline divergence (drives unplugged for extended periods)
- Use PostgreSQL-native logical replication for ongoing changes
- Integrate with existing mode-based state machine

## Goals / Non-Goals

### Goals
- Implement row-level diff+copy for bootstrap reconciliation
- Use PostgreSQL logical replication for ongoing streaming
- Support configurable schema list (start with `:users`, expand later)
- Maintain existing mode semantics and supervision tree structure
- Run PG sync alongside CubDB sync (non-breaking transition)

### Non-Goals
- Bi-directional simultaneous replication (always one writer at a time)
- Real-time sync (periodic replication is sufficient)
- Automatic schema migration during sync

## Decisions

### Decision 1: Use Electric Sync for diff+copy bootstrap
**What**: Leverage Electric Sync for unidirectional diff+copy during bootstrap. Direction is determined by mode:
- `:internal_to_main` mode: Sync missing data from internal → main
- `:main` mode: Sync missing data from main → internal

Electric Sync provides shape-based differential sync with CRDT-like semantics using immutable identifiers (public keys for users).

**Why**: 
- Battle-tested sync protocol designed for offline-first scenarios
- Handles differential sync efficiently (only transfers changed rows)
- Built-in CRDT-like conflict resolution using immutable identifiers
- Schema evolution support
- Optimized protocol built on PostgreSQL logical replication
- Less code to maintain vs custom implementation
- Already in the stack

**Alternatives considered**:
- Custom diff+copy implementation: Rejected - reinventing the wheel, Electric Sync already solves this
- Timestamp-based "newer wins": Rejected - doesn't preserve user choice in case of conflicts
- PostgreSQL `pg_dump`/`pg_restore`: Too coarse-grained, would drop target data
- PostgreSQL logical replication with `copy_data = true`: Unidirectional only, overwrites subscriber data
- File-level rsync: Doesn't work across running PostgreSQL clusters

### Decision 2: PostgreSQL logical replication for ongoing changes
**What**: Use `CREATE PUBLICATION` on writer, `CREATE SUBSCRIPTION` on follower with `copy_data = false` (since bootstrap already copied).

**Why**:
- Native PostgreSQL feature (available since PG 10)
- Efficient streaming of WAL changes
- Automatic conflict handling (last-write-wins on subscriber)
- No application-level polling needed

**Alternatives considered**:
- Periodic diff+copy: Too slow and resource-intensive for ongoing sync
- Trigger-based replication: More complex, requires application schema changes
- External tools (Bucardo, pglogical): Additional dependencies

### Decision 3: Direction control via mode state machine
**What**: 
- `:internal_to_main` mode → internal publishes, main subscribes
- `:main` / `:main_to_internal` mode → main publishes, internal subscribes
- Only one direction active at a time

**Why**:
- Prevents replication loops
- Clear single-writer semantics
- Matches existing CubDB behavior

### Decision 4: Module structure
**What**:
- `Platform.Storage.Sync` - orchestrates Electric Sync for diff+copy, tracks status
- `Platform.Storage.Pg.LogicalReplicator` - manages publications/subscriptions for ongoing replication
- `Platform.Storage.Pg.ElectricSync` - wrapper for Electric Sync client/integration

**Why**:
- Separation of concerns (orchestration vs replication vs Electric Sync integration)
- Electric Sync handles diff+copy internally (no need for custom Differ/Copier modules)
- Testable in isolation with mocks
- Follows existing `Platform.Storage.*` namespace conventions

## Risks / Trade-offs

### Risk: Logical replication requires replication user
**Mitigation**: 
- `Platform.Storage.Pg.Initializer` creates replication user during `initdb`
- Connection strings include replication credentials
- Document in `PG_REPLICATION.md`

### Risk: Schema changes break replication
**Mitigation**:
- Migrations run before sync starts (in `BootSupervisor`)
- Both clusters must have same schema version
- Future: Add schema version check before enabling replication

### Risk: Large divergence causes slow bootstrap
**Mitigation**:
- Show progress via `Platform.Leds.blink_write()`
- Log row counts and sync duration
- Future: Add incremental sync with checkpoints

### Trade-off: Periodic vs continuous replication
**Decision**: Use periodic health checks (every ~5 min) instead of continuous monitoring.

**Rationale**:
- Logical replication runs continuously in PostgreSQL background
- Application only needs to verify lag via `pg_stat_subscription`
- Reduces application complexity
- Matches existing `MainReplicator` interval pattern

## Migration Plan

### Phase 1: Implement core modules (this change)
1. Implement `Platform.Storage.Sync.run_local_sync/1` with diff+copy logic
2. Create `Platform.Storage.Pg.LogicalReplicator` for pub/sub management
3. Integrate into `InternalToMain.Copier` (runs after CubDB copy)
4. Add PG replication to `Logic.replicate_main_to_internal/0`
5. Test with `:users` schema only

### Phase 2: Expand schema coverage (future change)
- Add more schemas to `Platform.Storage.Sync.schemas/1` config
- Verify each schema has `updated_at` column
- Test with multiple schemas

### Phase 3: Retire CubDB sync (future change)
- Remove `Chat.Db.Copying` calls from `Copier` and `Logic`
- Remove `Chat.Db.Switching.mirror/2` calls
- Keep CubDB databases for backward compatibility (read-only)

### Rollback
- Set `config :platform, Platform.Storage.Sync, enabled: false` to disable PG sync
- CubDB sync continues to work independently
- No data loss (both sync mechanisms can coexist)

## Open Questions
None - design is ready for implementation.
