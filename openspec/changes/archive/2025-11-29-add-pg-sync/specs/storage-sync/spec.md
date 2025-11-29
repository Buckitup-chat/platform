# Storage Sync Specification (Delta)

## ADDED Requirements

### Requirement: Row-Level Diff and Copy
The system SHALL perform unidirectional row-level diff and copy synchronization between PostgreSQL clusters using Electric Sync, without dropping or recreating databases. Sync direction is determined by mode.

#### Scenario: Bootstrap sync from internal to main
- **GIVEN** mode is `:internal_to_main`
- **AND** internal PG has users A, B (with public keys)
- **AND** main PG has user B (with public key)
- **WHEN** `Platform.Storage.Sync.run_local_sync/1` is called with source=internal, target=main
- **THEN** Electric Sync copies user A to main (missing on target)
- **AND** user B on main is preserved (existing user kept, not replaced)
- **AND** no databases are dropped or recreated

#### Scenario: Bootstrap sync from main to internal
- **GIVEN** mode is `:main`
- **AND** main PG has users B, C (with public keys)
- **AND** internal PG has user B (with public key)
- **WHEN** `Platform.Storage.Sync.run_local_sync/1` is called with source=main, target=internal
- **THEN** Electric Sync copies user C to internal (missing on target)
- **AND** user B on internal is preserved (existing user kept, not replaced)
- **AND** no databases are dropped or recreated

#### Scenario: Initial sync to empty target
- **GIVEN** mode is `:internal_to_main`
- **AND** internal PG has users A, B, C
- **AND** main PG has no users
- **WHEN** `Platform.Storage.Sync.run_local_sync/1` is called with source=internal, target=main
- **THEN** Electric Sync copies all users A, B, C to main
- **AND** sync completes successfully

#### Scenario: Sync with no changes needed
- **GIVEN** source and target have identical user data
- **WHEN** `Platform.Storage.Sync.run_local_sync/1` is called
- **THEN** Electric Sync detects no differences
- **AND** no rows are copied or updated
- **AND** sync completes successfully

### Requirement: Configurable Schema List
The system SHALL support configurable list of schemas/tables to synchronize, each with its own conflict resolution identifier.

#### Scenario: Sync only users schema
- **GIVEN** config has `schemas: [:users]`
- **WHEN** `Platform.Storage.Sync.run_local_sync/1` is called
- **THEN** only users table is synchronized
- **AND** other tables are not affected

#### Scenario: Sync multiple schemas
- **GIVEN** config has `schemas: [:users, :messages, :files]`
- **WHEN** `Platform.Storage.Sync.run_local_sync/1` is called
- **THEN** all three tables are synchronized in order
- **AND** each table uses its own conflict resolution identifier (e.g., public key for users)

### Requirement: Conflict Resolution
The system SHALL use Electric Sync's CRDT-like "keep existing" strategy based on immutable identifiers (public keys for users) for unidirectional sync.

#### Scenario: User exists on both sides
- **GIVEN** source PG has user A with public key PK1
- **AND** target PG has user A with public key PK1
- **WHEN** Electric Sync runs
- **THEN** existing user A on target is preserved (not replaced)
- **AND** no update is performed

#### Scenario: User exists only on source
- **GIVEN** source PG has user A with public key PK1
- **AND** target PG does not have user with public key PK1
- **WHEN** Electric Sync runs
- **THEN** user A is copied to target
- **AND** Electric Sync uses conflict resolution based on public key

#### Scenario: User exists only on target
- **GIVEN** target PG has user B with public key PK2
- **AND** source PG does not have user with public key PK2
- **WHEN** Electric Sync runs
- **THEN** user B remains on target (unidirectional sync, no reverse copy)
- **AND** user B will be synced in opposite direction when mode changes

### Requirement: PostgreSQL Logical Replication
The system SHALL use PostgreSQL logical replication for ongoing change streaming after bootstrap sync.

#### Scenario: Enable internal to main replication
- **GIVEN** bootstrap sync from internal to main is complete
- **AND** mode is `:internal_to_main`
- **WHEN** `Platform.Storage.Pg.LogicalReplicator.create_publication/3` is called on internal repo
- **AND** `Platform.Storage.Pg.LogicalReplicator.create_subscription/4` is called on main repo with `copy_data: false`
- **THEN** publication `internal_to_main` is created on internal PG
- **AND** subscription `main_from_internal` is created on main PG
- **AND** changes to internal PG are streamed to main PG

#### Scenario: Switch replication direction on mode change
- **GIVEN** mode changes from `:internal_to_main` to `:main`
- **WHEN** `Platform.Storage.InternalToMain.Switcher` initializes
- **THEN** internal→main subscription is disabled
- **AND** main→internal publication is created on main PG
- **AND** internal→main subscription is created on internal PG
- **AND** changes to main PG are streamed to internal PG

#### Scenario: Check replication lag
- **GIVEN** logical replication is active
- **WHEN** `Platform.Storage.Pg.LogicalReplicator.check_replication_lag/2` is called
- **THEN** lag is queried from `pg_stat_subscription`
- **AND** lag value in bytes and seconds is returned

### Requirement: Sync Status Tracking
The system SHALL track synchronization status using persistent_term.

#### Scenario: Sync lifecycle states
- **GIVEN** sync is not running
- **WHEN** `Platform.Storage.Sync.status/0` is called
- **THEN** state is `:inactive`
- **WHEN** `Platform.Storage.Sync.set_active/0` is called
- **THEN** state changes to `:active`
- **WHEN** sync completes successfully
- **AND** `Platform.Storage.Sync.set_done/0` is called
- **THEN** state changes to `:done`

#### Scenario: Sync error handling
- **GIVEN** sync is running
- **WHEN** an error occurs during sync
- **AND** `Platform.Storage.Sync.set_error/1` is called with reason
- **THEN** state changes to `{:error, reason}`
- **AND** error is logged

### Requirement: Integration with InternalToMain Workflow
The system SHALL integrate PostgreSQL sync into the existing internal-to-main copy workflow.

#### Scenario: PG sync after CubDB copy
- **GIVEN** `Platform.Storage.InternalToMain.Copier` is running
- **AND** CubDB copy completes successfully
- **WHEN** PG sync is enabled
- **THEN** `Platform.Storage.Sync.run_local_sync/1` is called with source=internal repo, target=main repo
- **AND** sync runs before mode switches to `:main`
- **AND** logical replication is enabled after sync completes

#### Scenario: Skip PG sync when disabled
- **GIVEN** config has `enabled: false`
- **WHEN** `Platform.Storage.InternalToMain.Copier` runs
- **THEN** PG sync is skipped
- **AND** only CubDB copy runs

### Requirement: Integration with MainReplicator
The system SHALL integrate PostgreSQL replication into periodic main-to-internal replication.

#### Scenario: Periodic replication health check
- **GIVEN** mode is `:main`
- **AND** `Platform.Storage.MainReplicator` triggers periodic replication
- **WHEN** `Platform.Storage.Logic.replicate_main_to_internal/0` is called
- **THEN** replication lag is checked via `LogicalReplicator.check_replication_lag/2`
- **AND** if lag is acceptable, no action is taken
- **AND** CubDB replication continues to run

#### Scenario: Catch-up sync on high lag
- **GIVEN** replication lag exceeds threshold
- **WHEN** periodic replication runs
- **THEN** light-weight `Platform.Storage.Sync.run_local_sync/1` is called to reconcile drift
- **AND** logical replication continues afterward

### Requirement: Replication User Setup
The system SHALL create and configure a PostgreSQL replication user during initialization.

#### Scenario: Initialize replication user
- **GIVEN** `Platform.Storage.Pg.Initializer` is initializing a new PostgreSQL cluster
- **WHEN** initialization runs
- **THEN** replication user is created with REPLICATION privilege
- **AND** `pg_hba.conf` is updated to allow replication connections
- **AND** replication user credentials are stored in config

### Requirement: Observability and Logging
The system SHALL provide detailed logging for synchronization operations.

#### Scenario: Log sync operations
- **GIVEN** sync is running
- **WHEN** `Platform.Storage.Sync.run_local_sync/1` starts
- **THEN** log includes source repo, target repo, and schemas
- **WHEN** sync completes
- **THEN** log includes row counts, duration, and final status

#### Scenario: Log replication events
- **GIVEN** logical replication is active
- **WHEN** publication or subscription is created/modified
- **THEN** log includes operation, publication/subscription name, and result
- **WHEN** replication lag is checked
- **THEN** log includes lag value and timestamp

### Requirement: Backward Compatibility
The system SHALL run PostgreSQL sync alongside existing CubDB sync without breaking changes.

#### Scenario: Coexistence with CubDB sync
- **GIVEN** both CubDB and PG sync are enabled
- **WHEN** `Platform.Storage.InternalToMain.Copier` runs
- **THEN** CubDB copy runs first
- **AND** PG sync runs second
- **AND** both complete successfully
- **AND** mode switches to `:main` only after both complete

#### Scenario: Gradual schema migration (future expansion)
- **GIVEN** some schemas are in CubDB, others in PostgreSQL
- **WHEN** sync runs
- **THEN** only PostgreSQL schemas listed in config are synchronized
- **AND** CubDB schemas continue to use CubDB replication
- **NOTE**: This scenario is for future expansion when migrating schemas from CubDB to PostgreSQL
