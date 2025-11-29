# Implementation Tasks

## 1. Core Modules Implementation
- [x] 1.1 Create `Platform.Tools.Postgres.ElectricSync` module for Electric Sync integration
  - [x] Wrap Electric Sync client for unidirectional sync
  - [x] Configure sync shapes for users table using public key as identifier
  - [x] Support configurable conflict resolution identifier per schema
  - [x] Handle Electric Sync connection lifecycle
- [x] 1.2 Implement `Platform.Storage.Sync.run_local_sync/1` using Electric Sync
  - [x] Determine sync direction based on mode (`:internal_to_main` or `:main_to_internal`)
  - [x] Iterate over configured schemas
  - [x] Call `ElectricSync` to perform unidirectional diff+copy
  - [x] Update status via `set_active/0`, `set_done/0`, `set_error/1`
  - [x] Log row counts and sync duration
- [x] 1.4 Create `Platform.Tools.Postgres.LogicalReplicator` module
  - [x] Implement `create_publication/3` (repo, tables, publication_name)
  - [x] Implement `create_subscription/4` (repo, connection_string, publication_name, subscription_name)
  - [x] Implement `enable_subscription/2` and `disable_subscription/2`
  - [x] Implement `check_replication_lag/2` via `pg_stat_subscription`
  - [x] Use repo.query/1 for SQL execution

## 2. Integration with Existing Workflows
- [x] 2.1 Update `Platform.Storage.InternalToMain.Copier`
  - [x] After CubDB copy completes, call `Sync.run_local_sync/1`
  - [x] After sync completes, call `LogicalReplicator.create_publication/3` on internal repo
  - [x] Create subscription on main repo for internal→main replication
- [x] 2.2 Update `Platform.Storage.Logic.do_replicate_to_internal/0`
  - [x] Check replication lag via `LogicalReplicator.check_replication_lag/2`
  - [x] Optionally run light-weight `Sync.run_local_sync/1` if lag is high
  - [x] Keep existing CubDB replication for backward compatibility
- [x] 2.3 Update `Platform.Storage.InternalToMain.Switcher`
  - [x] On init (mode → `:main`): disable internal→main subscription, enable main→internal subscription
  - [x] On exit (mode → `:main_to_internal`): disable main→internal subscription

## 3. PostgreSQL Setup
- [ ] 3.1 Update `Platform.Storage.Pg.Initializer`
  - [ ] Create replication user during `initdb` (if not exists)
  - [ ] Grant replication privileges to replication user
  - [ ] Update `pg_hba.conf` to allow replication connections
- [x] 3.2 Add configuration for replication connection strings
  - [x] Internal PG connection string (host, port, user, password)
  - [x] Main PG connection string (host, port, user, password)
  - [x] Derive from existing repo config using `repo.config()`

## 4. Testing
- [ ] 4.1 Unit tests for `Platform.Storage.Pg.ElectricSync`
  - [ ] Mock Electric Sync client
  - [ ] Test shape configuration for users table
  - [ ] Test unidirectional sync (internal→main and main→internal)
  - [ ] Test connection lifecycle management
- [ ] 4.2 Integration tests with Electric Sync
  - [ ] Test sync with missing rows on target
  - [ ] Test existing rows are preserved (CRDT-like behavior)
  - [ ] Test sync with empty target
  - [ ] Test sync direction based on mode
- [ ] 4.3 Unit tests for `Platform.Storage.Pg.LogicalReplicator`
  - [ ] Mock SQL execution via `Platform.Tools.Postgres`
  - [ ] Test publication creation
  - [ ] Test subscription creation/enable/disable
  - [ ] Test lag checking
- [ ] 4.4 Integration tests for `Platform.Storage.Sync`
  - [ ] Test full sync flow with `:users` schema
  - [ ] Test sync with diverged data
  - [ ] Test sync with empty target
  - [ ] Test error handling and status updates
- [ ] 4.5 Integration tests for replication workflow
  - [ ] Test internal→main replication during `:internal_to_main`
  - [ ] Test main→internal replication during `:main`
  - [ ] Test subscription disable/enable on mode transitions
  - [ ] Test drive plug/unplug scenarios

## 5. Configuration and Documentation
- [x] 5.1 Add configuration options to `config/config.exs`
  - [x] `config :platform, Platform.Storage.Sync, enabled: true, schemas: [:users]`
  - [ ] Replication user credentials (deferred - needs infrastructure setup)
- [ ] 5.2 Update `PG_REPLICATION.md` with implementation details (optional)
  - [ ] Document module responsibilities
  - [ ] Document configuration options
  - [ ] Add troubleshooting section
- [x] 5.3 Add logging and observability
  - [x] Log sync start/complete/error with row counts
  - [x] Log replication lag metrics
  - [x] Log mode transitions and subscription changes

## 6. Validation and Deployment
- [ ] 6.1 Test on target hardware (SD card + USB drive)
  - [ ] Verify bootstrap sync works
  - [ ] Verify ongoing replication works
  - [ ] Verify drive removal/insertion handling
- [ ] 6.2 Performance testing
  - [ ] Measure sync time for various data sizes
  - [ ] Verify replication lag stays low (<1 second)
- [ ] 6.3 Deploy to staging environment
- [ ] 6.4 Monitor logs for errors or warnings
- [ ] 6.5 Deploy to production

## 7. Future Enhancements (Next Phase)
- [ ] 7.1 Migrate to Electric Sync for diff+copy
  - [ ] Leverage existing Electric server in Chat project
  - [ ] Replace `Platform.Storage.Pg.ElectricSync` minimal implementation with Electric client
  - [ ] Configure Electric shapes for users table
  - [ ] Test Electric-based sync vs current implementation
  - [ ] Measure performance improvements
- [ ] 7.2 Expand schema coverage
  - [ ] Add more schemas beyond `:users`
  - [ ] Configure conflict resolution identifiers per schema
- [ ] 7.3 Retire CubDB sync
  - [ ] Remove CubDB sync calls once PG sync is stable
  - [ ] Keep CubDB for backward compatibility (read-only)
