# PostgreSQL Management Requirements

## Document Overview

**Purpose**: Define requirements and architecture for PostgreSQL database management in the BuckitUp platform  
**Created**: 2026-01-10  
**Status**: Active

---

## 1. Current State Analysis

### 1.1 Architecture Components

The PostgreSQL management system consists of the following components:

#### Core Modules
- **Platform.Tools.Postgres**: Low-level PostgreSQL operations (initialize, start, stop, SQL execution)
- **Platform.Storage.Pg.Initializer**: Initialization stage (runs `initdb`, validates data directory)
- **Platform.Storage.Pg.Daemon**: Daemon supervision stage (starts postgres process, monitors health)
- **Platform.Storage.Pg.DbCreator**: Database creation stage (ensures target database exists)
- **Platform.Storage.Repo.Starter**: Ecto repository startup stage
- **Platform.Storage.Repo.MigrationRunner**: Database migration execution stage

#### Supervision Trees
1. **Internal Database** (`Platform.App.DatabaseSupervisor`):
   - Location: `/root/pg`
   - Port: `5432`
   - Stages: InitPg → PgServer → ChatDbCreated → ChatRepoStarted → ChatMigrationsRun → PhoenixSyncReady

2. **USB Drive Databases** (`Platform.App.Drive.BootSupervisor`):
   - Location: `/root/media/{device}/pg`
   - Ports: `5433+` (5432 + 1 + device_index)
   - Stages: Healed → Mounted → InitPg → PgServer → DbCreated → RepoStarted → MigrationsRun → InternalDbReady → Decider

### 1.2 Run Directory Strategy

**Base Directory**: `/tmp/pg_run`  
**Device-Specific Subdirectories**: `/tmp/pg_run/{device}`

Device name extraction logic:
- Parse `pg_dir` path: `/root/media/{device}/...` → extract device name
- Fallback: `"internal"` for `/root/pg`

**Rationale**: USB filesystems (FAT32, exFAT, NTFS) do not support Unix domain sockets and named pipes. PostgreSQL requires these for its socket file (`.s.PGSQL.{port}`). Using `/tmp` (tmpfs) ensures socket support.

### 1.3 PostgreSQL Configuration

#### Minimal Settings
```
shared_buffers=400kB
max_connections=50
dynamic_shared_memory_type=posix
max_prepared_transactions=0
max_locks_per_transaction=32
max_files_per_process=64
work_mem=1MB
wal_level=logical
listen_addresses=localhost
```

#### Recovery-Optimized Settings
```
checkpoint_timeout=5min (vs 30min default)
checkpoint_completion_target=0.9
max_wal_size=256MB (vs 1GB default)
min_wal_size=64MB
wal_compression=on
full_page_writes=off
fsync=off
synchronous_commit=off
wal_writer_delay=200ms
checkpoint_warning=30s
wal_sync_method=fdatasync
wal_buffers=256kB
bgwriter_delay=500ms
bgwriter_lru_maxpages=100
```

**Design Goal**: 90% focus on speed/absence of recovery, 10% on embedded constraints. Optimized for SD cards with faster recovery (5min max WAL replay vs 30min).

---

## 2. Problem Statement

### 2.1 Socket/Pipe Filesystem Compatibility
USB filesystems (FAT32, exFAT, NTFS) do not support Unix domain sockets and named pipes required by PostgreSQL. Solution implemented: use `/tmp/pg_run` for socket files.

### 2.2 Multi-Instance Management
System must support:
- 1 internal PostgreSQL instance (port 5432)
- Multiple USB drive instances (ports 5433+)
- Isolated run directories per instance
- No port/socket conflicts

### 2.3 Crash Recovery
PostgreSQL crashes must be handled gracefully:
- Stale shared memory cleanup
- Stale socket file cleanup
- Stale postmaster.pid removal
- Automatic restart (up to 3 attempts)
- Crash log capture for debugging

### 2.4 Initialization Validation
Invalid initialization must be detected and corrected:
- Verify essential files exist (PG_VERSION, base/1, global, pg_hba.conf)
- Retry initialization if validation fails (up to 5 attempts)
- Clean data directory between retries

---

## 3. Component Responsibilities

### 3.1 Platform.Tools.Postgres

**Purpose**: Low-level PostgreSQL operations wrapper

**Responsibilities**:
- Initialize PostgreSQL data directory (`initdb`)
- Start/stop PostgreSQL server (`pg_ctl`)
- Execute SQL commands (`psql`)
- Create databases (`createdb`)
- Check server health (`server_running?`)
- Manage run directories (create, cleanup, permissions)
- Clean up stale resources (shared memory, sockets, PIDs)
- Generate daemon specifications for MuonTrap
- Configure replication (pg_hba.conf)

**Key Functions**:
- `initialize/2`: Run initdb with validation and retry logic
- `start/1`: Start PostgreSQL using pg_ctl (legacy, not used in daemon mode)
- `stop/1`: Stop PostgreSQL using pg_ctl
- `daemon_spec/1`: Generate MuonTrap.Daemon specification
- `ensure_run_dir/2`: Create and configure device-specific run directory
- `cleanup_old_server/1`: Comprehensive cleanup before daemon start
- `server_running?/1`: Health check via psql connection test

### 3.2 Platform.Storage.Pg.Initializer

**Purpose**: Initialization stage in supervision tree

**Responsibilities**:
- Call `Postgres.initialize/1` in async task
- Handle initialization failures and crashes
- Trigger next stage on success
- Clean up POSIX shared memory on crash

**Lifecycle**:
1. Receive `:start` message
2. Spawn async task for initialization
3. Wait for task completion
4. On success: send `:initialized`, start next stage
5. On failure: stop with error reason

### 3.3 Platform.Storage.Pg.Daemon

**Purpose**: PostgreSQL daemon supervision and health monitoring

**Responsibilities**:
- Verify initialization before starting
- Capture crash logs before cleanup
- Clean up stale resources (old server, shared memory, sockets, PIDs)
- Start PostgreSQL daemon via MuonTrap.Daemon
- Monitor daemon health (30 attempts, 2s intervals)
- Handle daemon crashes (restart up to 3 times)
- Trigger next stage when ready

**Lifecycle**:
1. Receive `:start` message
2. Verify initialization
3. Capture any existing crash logs
4. Run cleanup_old_server
5. Start MuonTrap.Daemon with postgres binary
6. Send `:wait_for_ready` to self
7. Poll for server readiness (30 × 2s = 60s max)
8. On ready: start next stage
9. On crash: capture logs, restart (up to 3 times)

**Crash Handling**:
- Intercept `{:EXIT, daemon_pid, reason}` messages
- Restart count < 3: schedule restart after 2s delay
- Restart count ≥ 3: stop with error

### 3.4 Platform.Storage.Pg.DbCreator

**Purpose**: Database creation stage

**Responsibilities**:
- Ensure target database exists
- Call `Postgres.ensure_db_exists/2` in async task
- Trigger next stage on completion

### 3.5 Platform.Storage.Repo.Starter

**Purpose**: Ecto repository startup stage

**Responsibilities**:
- Start Ecto.Repo with dynamic configuration
- Handle port overrides for USB drive instances

### 3.6 Platform.Storage.Repo.MigrationRunner

**Purpose**: Database migration execution stage

**Responsibilities**:
- Run pending Ecto migrations
- Ensure schema is up to date

---

## 4. Lifecycle Flow

### 4.1 Internal Database Startup

```
DatabaseSupervisor.init
  ↓
TaskSupervisor (for async operations)
  ↓
Initializer.on_init → :start
  ↓
Initializer: async Postgres.initialize(pg_dir: /root/pg, pg_port: 5432)
  ↓
Postgres.initialize:
  - Create /root/pg/data
  - Ensure /tmp/pg_run/internal
  - Set permissions (postgres user/group)
  - Run initdb with minimal settings
  - Validate initialization (PG_VERSION, base/1, global, pg_hba.conf)
  - Setup replication (update pg_hba.conf)
  - Retry up to 5 times if validation fails
  ↓
Initializer: :initialized → start next stage
  ↓
Daemon.on_init → :start
  ↓
Daemon:
  - Verify initialization
  - Capture crash logs
  - cleanup_old_server (stop existing, clean shared memory)
  - ensure_run_dir (/tmp/pg_run/internal)
  - remove_stale_postmaster_pid
  - Start MuonTrap.Daemon with postgres binary
  - Args: -D /root/pg/data + minimal settings + recovery settings
          + unix_socket_directories=/tmp/pg_run/internal
          + port=5432
  ↓
Daemon: :wait_for_ready
  ↓
Daemon: Poll server_running? (30 attempts × 2s)
  ↓
Daemon: Health check passed → start next stage
  ↓
DbCreator: ensure_db_exists("chat", pg_port: 5432)
  ↓
Repo.Starter: Start Chat.Repo with port 5432
  ↓
MigrationRunner: Run Chat.Repo migrations
  ↓
PhoenixSyncInit: Initialize Phoenix PubSub sync
```

### 4.2 USB Drive Database Startup

```
Drive.BootSupervisor.init(device: "sda")
  ↓
Healer: Check/repair filesystem
  ↓
Mounter: Mount /root/media/sda with postgres uid/gid
  ↓
Initializer: Postgres.initialize(pg_dir: /root/media/sda/pg, pg_port: 5433)
  - Ensure /tmp/pg_run/sda
  ↓
Daemon: Start postgres on port 5433
  - unix_socket_directories=/tmp/pg_run/sda
  ↓
DbCreator: ensure_db_exists("chat", pg_port: 5433)
  ↓
Repo.Starter: Start Platform.Dev.Sda.Repo with port 5433
  ↓
MigrationRunner: Run migrations
  ↓
InternalDbAwaiter: Wait for internal DB to be ready
  ↓
Decider: Decide next action (backup, sync, etc.)
```

---

## 5. Issues and Risks

### 5.1 Current Issues

#### 5.1.1 pg_ctl Socket Directory Mismatch
**Issue**: `pg_ctl` commands (start, stop) don't specify socket directory, relying on default `/tmp`. When postgres daemon uses custom `unix_socket_directories`, pg_ctl may not find the socket.

**Impact**: 
- `cleanup_old_server` may fail to stop existing postgres
- `start/1` function (if used) may not work correctly
- `stop/1` function may not work correctly

**Status**: Low risk - daemon mode bypasses pg_ctl for starting. Only affects cleanup and manual stop operations.

#### 5.1.2 Race Condition in Socket Cleanup
**Issue**: `cleanup_run_dir_files` removes socket files, but postgres might be starting simultaneously.

**Impact**: Rare race condition where socket is removed during startup.

**Status**: Low risk - cleanup happens before daemon start in controlled sequence.

#### 5.1.3 Shared Memory Cleanup Not Device-Aware
**Issue**: `SharedMemory.cleanup_stale` uses pg_data_dir to identify shared memory segments, but multiple instances might conflict.

**Impact**: Shared memory from one instance might be cleaned up when starting another.

**Status**: Medium risk - needs investigation of shared memory segment naming.

#### 5.1.4 No Validation of /tmp as tmpfs
**Issue**: Code assumes `/tmp` is tmpfs (supports sockets), but doesn't validate.

**Impact**: If `/tmp` is on unsupported filesystem, postgres will fail to start.

**Status**: Low risk - standard Linux systems have tmpfs at `/tmp`.

#### 5.1.5 Hard-Coded Run Directory Path
**Issue**: `@pg_run_dir = "/tmp/pg_run"` is hard-coded, not configurable.

**Impact**: Cannot change run directory location without code modification.

**Status**: Low risk - `/tmp/pg_run` is appropriate for all use cases.

### 5.2 Potential Risks

#### 5.2.1 Disk Space Exhaustion
**Risk**: Multiple PostgreSQL instances on USB drives could exhaust disk space.

**Mitigation**: Monitor disk usage, implement cleanup policies.

#### 5.2.2 Port Conflicts
**Risk**: Port allocation formula (5432 + 1 + device_index) could conflict with other services.

**Mitigation**: Document port range, implement port availability check.

#### 5.2.3 Slow SD Card Recovery
**Risk**: SD card corruption could cause long recovery times despite optimizations.

**Mitigation**: Recovery-optimized settings reduce max recovery time to ~5min. Increase timeout if needed.

#### 5.2.4 Concurrent Initialization
**Risk**: Multiple USB drives plugged simultaneously could cause concurrent initialization issues.

**Mitigation**: Each drive has isolated supervision tree, separate run directories.

---

## 6. Requirements for Improvement

### 6.1 Functional Requirements

#### FR-1: Socket Directory Consistency
All PostgreSQL operations (initdb, pg_ctl, postgres daemon) MUST use the same socket directory.

**Acceptance Criteria**:
- pg_ctl commands include socket directory specification
- No socket directory mismatches in logs
- cleanup_old_server successfully stops existing postgres

#### FR-2: Device-Aware Resource Cleanup
Cleanup operations MUST be isolated per device to prevent cross-instance interference.

**Acceptance Criteria**:
- Shared memory cleanup targets specific instance
- Socket cleanup targets specific run directory
- PID file cleanup targets specific data directory

#### FR-3: Robust Crash Recovery
System MUST recover from PostgreSQL crashes without manual intervention.

**Acceptance Criteria**:
- Automatic restart on crash (up to 3 attempts)
- Crash logs captured for debugging
- Stale resources cleaned before restart
- Supervision tree continues after recovery

#### FR-4: Initialization Validation
Initialization MUST be validated before proceeding to daemon stage.

**Acceptance Criteria**:
- Essential files verified (PG_VERSION, base/1, global, pg_hba.conf)
- Invalid initialization triggers retry (up to 5 attempts)
- Data directory cleaned between retries

#### FR-5: Health Monitoring
PostgreSQL health MUST be continuously monitored.

**Acceptance Criteria**:
- Startup health check (30 attempts × 2s)
- Final health check before next stage
- Retry on health check failure

### 6.2 Non-Functional Requirements

#### NFR-1: Performance
- Initialization: < 30 seconds
- Daemon startup: < 60 seconds
- Health check: < 2 seconds per attempt
- Recovery time: < 5 minutes (WAL replay)

#### NFR-2: Reliability
- Crash recovery success rate: > 95%
- Initialization success rate: > 99%
- Uptime: > 99.9% (excluding intentional restarts)

#### NFR-3: Observability
- All operations logged with appropriate levels
- Crash logs captured and logged
- Health check status logged
- Resource cleanup logged

#### NFR-4: Maintainability
- Clear separation of concerns (Tools vs Stages)
- Configurable timeouts and retry counts
- Testable components (dependency injection via options)

---

## 7. Proposed Solutions

### 7.1 Fix pg_ctl Socket Directory Mismatch

**Problem**: pg_ctl doesn't know about custom socket directory.

**Solution**: Pass socket directory to pg_ctl via `-o` option or environment variable.

**Implementation**:
```elixir
# Option 1: Pass via -o (server options)
args = ["-D", pg_data_dir, "-o", "-k #{run_dir}", "stop", "-m", "fast"]

# Option 2: Set PGHOST environment variable
cmd_opts = [
  stderr_to_stdout: true,
  uid: get_postgres_uid(),
  gid: get_postgres_gid(),
  env: [{"PGHOST", run_dir}]
]
```

**Recommendation**: Use Option 2 (PGHOST) for consistency across all pg_* tools.

### 7.2 Improve Run Directory Management

**Problem**: Run directory logic is scattered and not fully consistent.

**Solution**: Centralize run directory management with explicit passing.

**Implementation**:
1. Add `run_dir` to all function options
2. Calculate run_dir once at supervisor level
3. Pass explicitly to all stages
4. Remove implicit calculation in `run_dir_for_pg_dir`

**Benefits**:
- Explicit over implicit
- Easier testing
- No hidden dependencies on pg_dir path structure

### 7.3 Enhance Shared Memory Cleanup

**Problem**: Shared memory cleanup might affect wrong instance.

**Solution**: Include port or device identifier in shared memory segment naming.

**Implementation**:
1. Investigate current shared memory segment naming
2. If needed, configure PostgreSQL to use unique segment names
3. Update cleanup logic to target specific segments

### 7.4 Add Configuration Validation

**Problem**: No validation that /tmp supports sockets.

**Solution**: Add startup validation for run directory.

**Implementation**:
```elixir
defp validate_run_dir(run_dir) do
  test_socket = Path.join(run_dir, ".test_socket")
  
  case :gen_tcp.listen(0, [:local, {:ifaddr, {:local, test_socket}}]) do
    {:ok, socket} ->
      :gen_tcp.close(socket)
      File.rm(test_socket)
      :ok
    {:error, reason} ->
      {:error, "Run directory #{run_dir} does not support sockets: #{reason}"}
  end
end
```

### 7.5 Improve Observability

**Problem**: Limited visibility into PostgreSQL state during startup/crashes.

**Solution**: Add structured logging and metrics.

**Implementation**:
1. Log all state transitions with context
2. Add timing metrics for each stage
3. Include device/port in all log messages
4. Structured crash reports with stack traces

---

## 8. Testing Strategy

### 8.1 Unit Tests

**Target**: Platform.Tools.Postgres functions

**Scenarios**:
- Initialize with valid/invalid directories
- Start/stop with various configurations
- Run directory creation and cleanup
- Socket file cleanup
- Shared memory cleanup
- Health checks

**Mocking**: Use Rewire for MuonTrap, File operations

### 8.2 Integration Tests

**Target**: Full initialization → daemon → database flow

**Scenarios**:
- Internal database startup
- USB drive database startup
- Multiple concurrent USB drives
- Crash and recovery
- Invalid initialization retry

**Environment**: Test with actual PostgreSQL binary

### 8.3 Failure Tests

**Scenarios**:
- PostgreSQL crash during startup
- PostgreSQL crash during operation
- Disk full during initialization
- Corrupted data directory
- Missing postgres binary
- Permission issues

---

## 9. Migration Plan

### 9.1 Phase 1: Fix Critical Issues
- Implement pg_ctl socket directory fix
- Add run_dir explicit passing
- Enhance logging

### 9.2 Phase 2: Improve Robustness
- Enhance shared memory cleanup
- Add configuration validation
- Improve crash recovery

### 9.3 Phase 3: Optimize
- Performance tuning
- Reduce startup time
- Optimize health checks

---

## 10. Appendix

### 10.1 PostgreSQL File Structure

```
/root/pg/                          (internal)
├── data/
│   ├── PG_VERSION
│   ├── base/
│   │   └── 1/                     (template1 database)
│   ├── global/                    (shared catalogs)
│   ├── pg_hba.conf                (authentication config)
│   ├── postgresql.conf            (server config)
│   ├── postmaster.pid             (server PID file)
│   └── pg_wal/                    (write-ahead log)

/tmp/pg_run/internal/              (socket directory)
├── .s.PGSQL.5432                  (Unix socket)
└── .s.PGSQL.5432.lock             (socket lock)

/root/media/sda/pg/                (USB drive)
├── data/                          (same structure as internal)

/tmp/pg_run/sda/                   (USB socket directory)
├── .s.PGSQL.5433
└── .s.PGSQL.5433.lock
```

### 10.2 Port Allocation

| Instance | Port | Run Directory | Data Directory |
|----------|------|---------------|----------------|
| Internal | 5432 | /tmp/pg_run/internal | /root/pg/data |
| sda | 5433 | /tmp/pg_run/sda | /root/media/sda/pg/data |
| sdb | 5434 | /tmp/pg_run/sdb | /root/media/sdb/pg/data |
| sdc | 5435 | /tmp/pg_run/sdc | /root/media/sdc/pg/data |

### 10.3 Key Configuration Files

**pg_hba.conf** (authentication):
```
# Replication connections
host    replication     postgres     127.0.0.1/32            trust
host    replication     postgres     ::1/128                 trust
local   replication     postgres                             trust
```

**postgresql.conf** (passed as command-line args):
```
unix_socket_directories = /tmp/pg_run/{device}
port = {port}
shared_buffers = 400kB
max_connections = 50
...
```

### 10.4 MuonTrap.Daemon Specification

```elixir
{MuonTrap.Daemon,
 [
   "/usr/bin/postgres",
   ["-D", pg_data_dir] ++
     @pg_minimal_settings ++
     @pg_recovery_optimized_settings ++
     [
       "-c", "unix_socket_directories=#{run_dir}",
       "-c", "port=#{pg_port}",
       "-c", "log_destination=stderr"
     ],
   [
     stderr_to_stdout: true,
     log_output: :debug,
     uid: get_postgres_uid(),
     gid: get_postgres_gid(),
     name: daemon_name
   ]
 ]}
```

### 10.5 References

- PostgreSQL Documentation: https://www.postgresql.org/docs/
- MuonTrap: https://github.com/fhunleth/muon_trap
- Elixir Supervisor: https://hexdocs.pm/elixir/Supervisor.html
- Ecto: https://hexdocs.pm/ecto/
