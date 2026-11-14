# storage-sync Specification

## Purpose
Keep PostgreSQL data, CubDB data and chunk blobs consistent between storage units (internal SD, main USB, backup USB) through **links**: directed `from ~> to` flows that carry all three layers at once. Links, their status and the PG tooling live in chat (`Chat.Storage.Link`, `Chat.Storage.Links`, `Chat.Storage.Pg.*`); platform decides which link plan runs per drive (`Platform.Storage.MainPlan`, `Platform.Storage.BackupPlan`).

Full design: `chat/docs/pq/reqs/files/pq_storage_units.done.md` (§2.7). This spec replaces the earlier mode-driven design (`Platform.Storage.Sync`, `InternalToMain.Copier` / `Switcher`, `MainReplicator`), which has been removed.

## Requirements
### Requirement: Row-Level Diff and Copy (Link Bootstrap)
The system SHALL bring unit `to` up to date from unit `from` with a one-shot, row-level diff and copy, without dropping or recreating databases. Direction is given by the link, not by a global mode.

#### Scenario: Bootstrap internal ~> main
- **GIVEN** internal PG has users A, B
- **AND** main PG has user B
- **WHEN** `Chat.Storage.Link.bootstrap/1` runs for `internal ~> main`
- **THEN** `Chat.Storage.Pg.BatchSync` copies user A to main
- **AND** user B on main is preserved (`ON CONFLICT DO NOTHING`)
- **AND** no databases are dropped or recreated

#### Scenario: Bootstrap queues missing blobs
- **GIVEN** a `file_chunks` row is copied to `to`
- **AND** `to` has no blob for it under `Unit.path(to, :pq_files)`
- **WHEN** the bootstrap finishes its row layer
- **THEN** a `missing_chunks` row is created on `to` with `source_drive_id = from.system_id`
- **AND** `{:chunk_pipeline, :pg_diff_copied}` is broadcast so `to`'s chunk pipeline pulls the blob

#### Scenario: CubDB layer
- **GIVEN** both units have the `:cub` capability and both CubDBs are running
- **WHEN** the link bootstraps
- **THEN** CubDB data is copied with `Chat.Db.Copying.await_copied/3` before the PG layer

#### Scenario: Failure stops later layers
- **WHEN** a bootstrap layer returns `{:error, reason}`
- **THEN** the layers after it do not run
- **AND** a full disk on `to` is reported as `{:error, :disk_full}`

### Requirement: Configurable Schema List
The system SHALL sync only the schemas the link's filter selects; with no filter, the schemas from `Chat.Data.Shapes.sync_schemas/0`.

#### Scenario: Filtered link
- **GIVEN** a link with `%Chat.Storage.Link.Filter{schemas: [...]}`
- **WHEN** it bootstraps or replicates
- **THEN** only those tables are diff-copied and published

### Requirement: PostgreSQL Logical Replication (Link Replicate)
The system SHALL stream ongoing changes from `from` to `to` with PostgreSQL logical replication after bootstrap.

#### Scenario: Start replication
- **WHEN** `Chat.Storage.Link.replicate/1` runs for `internal ~> main`
- **THEN** publication `internal_to_main` is created on internal PG
- **AND** a fresh slot and subscription `main_from_internal` are created (names from `Link.name/2`)
- **AND** internal is registered as the replication source of main, so `ReplicationListener` stamps `missing_chunks.source_drive_id` with internal's `system_id`
- **AND** internal's CubDB writes are mirrored to main

#### Scenario: Stop replication
- **WHEN** `Chat.Storage.Link.stop/1` runs
- **THEN** the CubDB mirror is removed
- **AND** the subscription on `to` is dropped if `to` is still up
- **AND** the slot on `from` is always dropped, so an ejected `to` leaves no WAL retained on `from`

#### Scenario: Check replication lag
- **GIVEN** a link is replicating
- **WHEN** `LinkRunner` polls `Chat.Storage.Link.lag/1`
- **THEN** lag in bytes is read via `Chat.Storage.Pg.LogicalReplicator.check_replication_lag/2`
- **AND** recorded in `Chat.Storage.Links` as `lag_bytes`

### Requirement: Main Drive Plans
The system SHALL attach and eject a main drive by running link plans with `Chat.Storage.PlanRunner`.

#### Scenario: Attach main
- **WHEN** `Platform.Storage.MainPlan` starts for a main drive
- **THEN** it runs `:main_attach`: bootstrap `internal ~> main`, replicate `internal ~> main`, bootstrap `main ~> internal`, stop `internal ~> main`, replicate `main ~> internal`, switch Default to main
- **AND** the Default switch goes through `Chat.Storage.Default.switch_to/1`

#### Scenario: Eject main
- **WHEN** `MainPlan` exits for any reason (eject, crash, restart)
- **THEN** it stops the attach runner's links and runs `:main_eject`: stop `main ~> internal`, switch Default to internal

### Requirement: Backup Drive Plans
The system SHALL back up to a backup drive against the current Default unit.

#### Scenario: One-shot backup
- **GIVEN** backup settings are not continuous
- **WHEN** `Platform.Storage.BackupPlan` starts
- **THEN** it runs `:backup_once`: bootstrap `backup ~> default` (restore), bootstrap `default ~> backup`, await chunks on both links, eject

#### Scenario: Continuous backup
- **GIVEN** backup settings are continuous
- **WHEN** `BackupPlan` starts
- **THEN** it runs `:backup_continuous`: the one-shot steps without eject, then replicate `default ~> backup`

#### Scenario: Default switches during backup
- **WHEN** `{:default_switched, new}` is broadcast on `"storage"`
- **THEN** a running plan is restarted against the new Default
- **AND** a finished continuous plan re-homes with `:backup_rehome` (stop `old ~> backup`, bootstrap `new ~> backup`, replicate `new ~> backup`)

### Requirement: Link Status Tracking
The system SHALL track the status of every link in one place, `Chat.Storage.Links`.

#### Scenario: Status lifecycle
- **THEN** a link's status is one of `:idle`, `{:bootstrapping, progress}`, `:replicating`, `{:awaiting, {done, total}}`, `:stopped`, `{:partial, map}`, `{:error, term}`
- **AND** `Platform.Storage.Logic.info/0` reports the Default unit's role and `Links.list()`

### Requirement: Replication Setup
The system SHALL configure each PostgreSQL cluster for logical replication when it is initialized.

#### Scenario: Initialize cluster
- **GIVEN** `Platform.Tools.Postgres.Lifecycle` initializes a new cluster
- **THEN** the cluster runs with `wal_level=logical`
- **AND** replication is set up by `Platform.Tools.Postgres.Database.setup_replication/1`

### Requirement: Observability and Logging
The system SHALL log link operations.

#### Scenario: Log link steps
- **WHEN** a link bootstraps, replicates, stops or fails
- **THEN** the log names the link id (`{from_role, to_role}`) and the result
