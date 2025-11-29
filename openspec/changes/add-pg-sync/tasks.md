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
- [x] 3.1 Update `Platform.Storage.Pg.Initializer`
  - [x] Create replication user during `initdb` (if not exists)
  - [x] Grant replication privileges to replication user
  - [x] Update `pg_hba.conf` to allow replication connections
- [x] 3.2 Add configuration for replication connection strings
  - [x] Internal PG connection string (host, port, user, password)
  - [x] Main PG connection string (host, port, user, password)
  - [x] Derive from existing repo config using `repo.config()`

## 4. Testing
- [x] 4.1 Unit tests for `Platform.Tools.Postgres.ElectricSync`
  - [x] Mock Ecto repos for source and target
  - [x] Test shape configuration for users table (pub_key identifier)
  - [x] Test unidirectional sync (internal→main and main→internal)
  - [x] Test connection lifecycle management
  - [x] Test CRDT-like behavior (ON CONFLICT DO NOTHING)
  - [x] Test error handling and statistics
  - [x] Uses Chat.Data.Schemas.User from Chat dependency (no mock needed)
- [x] 4.2 Integration tests with Electric Sync
  - [x] Test sync with missing rows on target
  - [x] Test existing rows are preserved (CRDT-like behavior)
  - [x] Test sync with empty target
  - [x] Test sync direction based on mode (internal→main and main→internal)
  - [x] Test partial sync (some rows already exist)
  - [x] Test binary pub_key handling
  - [x] Test statistics reporting
  - [x] Created test repos (InternalRepo, MainRepo)
  - [x] Created DatabaseHelper for setup/teardown
  - [x] 8 integration tests passing
- [x] 4.3 Unit tests for `Platform.Tools.Postgres.LogicalReplicator`
  - [x] Mock Ecto repo for SQL execution
  - [x] Test publication creation with idempotency
  - [x] Test subscription creation with options (copy_data, enabled)
  - [x] Test enable/disable subscription
  - [x] Test lag checking via pg_stat_subscription
  - [x] Test error handling for all operations
- [x] 4.4 Integration tests for `Platform.Storage.Sync`
  - [x] Test full sync flow with `:users` schema
  - [x] Test sync with diverged data
  - [x] Test sync with empty target
  - [x] Test error handling and status updates
  - [x] Test missing repo error handling
  - [x] Test default schemas
  - [x] Test large dataset sync (100 users)
  - [x] Test status management (inactive, active, done, error)
  - [x] Test configuration (enabled?, schemas/1)
  - [x] 11 integration tests passing
- [x] 4.5 Integration tests for replication workflow
  - [x] Test internal→main replication during `:internal_to_main`
  - [x] Test main→internal replication during `:main`
  - [x] Test subscription disable/enable on mode transitions
  - [x] Test drive plug/unplug scenarios
  - [x] 6 integration tests passing (publication setup, bootstrap sync, mode transitions, data divergence)

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
