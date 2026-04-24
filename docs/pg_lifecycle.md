# PostgreSQL Initialization Lifecycle

## Overview

This document describes the PostgreSQL initialization and supervision architecture in the Platform firmware. The system manages multiple PostgreSQL instances:
- **Internal database** (`/root/pg`) - for the chat application on the device
- **Per-USB-drive databases** (`/media/{device}/pg`) - one instance per connected USB drive

## Supervision Tree Hierarchy

```
Platform.Application
├── Platform.App.DeviceSupervisor
│   ├── DynamicSupervisor (Platform.Drives)
│   │   └── Platform.App.Drive.BootSupervisor (per USB device: sda, sdb, etc.)
│   │       └── [Staged PG initialization tree]
│   ├── Registry (Platform.Drives.Registry)
│   └── Platform.UsbDrives.Detector.Watcher (target only)
│
└── Platform.App.DatabaseSupervisor (target only)
    └── [Staged PG initialization tree for internal DB]
```

## Staged Supervision Pattern

The platform implements a "staged supervision" pattern in `lib/platform.ex` that chains initialization stages sequentially:

### Stage Types

1. **`:stage`** - Long-running workers (DynamicSupervisor created BEFORE child)
   - Child runs indefinitely, supervises next stages
   - Example: `Pg.Daemon`, `Repo.Starter`

2. **`:step`** - One-time operations (child starts FIRST, then DynamicSupervisor)
   - Child completes work, then triggers next stage
   - Example: `Pg.Initializer`, `Pg.DbCreator`, `MigrationRunner`

### Stage Propagation

Each stage receives `next: [under: stage_name, run: next_tree]` in its options:
- `under` - DynamicSupervisor to start next stage under
- `run` - Child specs for the next stage

Stages call `Platform.start_next_stage(next_supervisor, next_specs)` upon completion.

## Per-Drive Boot Sequence

**File:** `lib/platform/app/drive/boot_supervisor.ex`

```
DriveIndicationStarter (15s timeout)
       ↓
STAGE: Healer (Platform.Storage.Healer)
       ↓
STEP:  Mounter (15s) → mounts drive with postgres uid:gid
       ↓
STEP:  InitPg (30s) → Platform.Storage.Pg.Initializer
       │
       │  ┌─────────────────────────────────────────┐
       │  │ 1. Create /media/{dev}/pg/data          │
       │  │ 2. Set permissions (postgres:postgres)  │
       │  │ 3. Run initdb with minimal settings     │
       │  │ 4. Validate init (PG_VERSION, base/1,   │
       │  │    global, pg_hba.conf)                 │
       │  │ 5. Setup replication in pg_hba.conf     │
       │  │ 6. Retry up to 5x if validation fails   │
       │  └─────────────────────────────────────────┘
       ↓
STAGE: PgServer (180s) → Platform.Storage.Pg.Daemon
       │
       │  ┌─────────────────────────────────────────┐
       │  │ 1. Cleanup old server (pg_ctl stop)     │
       │  │ 2. Cleanup stale shared memory          │
       │  │ 3. Ensure run_dir (/tmp/pg_run/{dev})   │
       │  │ 4. Remove stale postmaster.pid          │
       │  │ 5. Start postgres via MuonTrap.Daemon   │
       │  │ 6. Wait for ready (30 retries × 2s)     │
       │  │ 7. Health check via psql SELECT 1       │
       │  │ 8. Handle crashes (max 3 restarts)      │
       │  └─────────────────────────────────────────┘
       ↓
STEP:  DbCreated (15s) → ensures 'chat' database exists
       ↓
STAGE: RepoStarted (30s) → Platform.Storage.Repo.Starter
       │
       │  ┌─────────────────────────────────────────┐
       │  │ 1. Dynamically create repo module       │
       │  │    Platform.Dev.Sd{X}.Repo              │
       │  │ 2. Start Ecto.Repo with port override   │
       │  │ 3. Keep repo alive (long-running stage) │
       │  └─────────────────────────────────────────┘
       ↓
STEP:  MigrationsRun (60s) → Platform.Storage.Repo.MigrationRunner
       │
       │  ┌─────────────────────────────────────────┐
       │  │ 1. Wait for repo ready (30 attempts)    │
       │  │ 2. Run Chat.RepoStarter.run_migrations  │
       │  │ 3. Ensure ElectricSQL slot exists       │
       │  └─────────────────────────────────────────┘
       ↓
STEP:  InternalDbReady → waits for internal database
       ↓
STAGE: Scenario (90s) → DynamicSupervisor for next supervisors
       ↓
       Decider → makes decisions about drive state
```

### Port Allocation

```elixir
pg_port = 5432 + 1 + (device_letter - 'a')
# sda → 5433, sdb → 5434, sdc → 5435, etc.
# Internal → 5432
```

### Path Structure

```
/media/{device}/pg/
├── data/                    # PostgreSQL data directory
│   ├── PG_VERSION
│   ├── base/1/
│   ├── global/
│   ├── pg_hba.conf
│   └── postmaster.pid       # PID file
│
/tmp/pg_run/{device}/        # Runtime directory (sockets)
└── .s.PGSQL.{port}          # Unix socket
```

## Key Module Responsibilities

### Platform.Storage.Pg.Initializer
- **Type:** Step (GracefulGenServer, 1min timeout)
- **Purpose:** Initialize PostgreSQL data directory
- **Flow:** `on_init` → send `:start` → spawn async task → `Postgres.initialize()` → `:initialized` → `start_next_stage`

### Platform.Storage.Pg.Daemon
- **Type:** Stage (GracefulGenServer, 3min timeout)
- **Purpose:** Run and monitor PostgreSQL daemon
- **Flow:** `on_init` → `:start` → cleanup → start MuonTrap.Daemon → `:wait_for_ready` → health check → `start_next_stage`
- **Crash handling:** Captures EXIT, restarts up to 3 times with 2s delay

### Platform.Storage.Pg.DbCreator
- **Type:** Step (GracefulGenServer, 1min timeout)
- **Purpose:** Ensure database exists
- **Flow:** `on_init` → `:start` → spawn async task → `Postgres.ensure_db_exists()` → `:db_ready` → `start_next_stage`

### Platform.Storage.Repo.Starter
- **Type:** Stage (GracefulGenServer, 3min timeout)
- **Purpose:** Start and keep Ecto.Repo alive
- **Flow:** `on_init` → `:start` → `repo_name.start_link()` → `start_next_stage` → keep running

### Platform.Storage.Repo.MigrationRunner
- **Type:** Step (GracefulGenServer, 3min timeout)
- **Purpose:** Run database migrations
- **Flow:** `on_init` → `:start` → spawn async task → wait for repo → run migrations → ensure slot → `:migrations_done` → `start_next_stage`

## PostgreSQL Configuration

### Minimal Settings (Embedded Constraints)
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

### Recovery-Optimized Settings (SD Card)
```
checkpoint_timeout=5min          # 6x faster recovery vs 30min default
max_wal_size=256MB              # 4x less WAL to replay
min_wal_size=64MB
checkpoint_completion_target=0.9
wal_compression=on
full_page_writes=off            # No crash safety, faster writes
fsync=off                       # Dangerous but fast
synchronous_commit=off
wal_writer_delay=200ms
wal_buffers=256kB
bgwriter_delay=500ms
bgwriter_lru_maxpages=100
```

---

# Weak Points Analysis

## 1. Supervision Strategy Mismatches

### Problem: `rest_for_one` with Mixed Stage Types
**Location:** `lib/platform/app/drive/boot_supervisor.ex:24`

```elixir
Supervisor.init(strategy: :rest_for_one, max_restarts: 1, max_seconds: 5)
```

The boot supervisor uses `:rest_for_one`, but stages have wildly different lifetimes:
- Long-running stages (`Pg.Daemon`, `Repo.Starter`) should restart dependents
- One-time steps (`Initializer`, `DbCreator`) complete and wait

**Issue:** If `Repo.Starter` crashes, `:rest_for_one` restarts `MigrationRunner` and later stages—but MigrationRunner may run migrations again on an already-migrated database.

**BEAM Fix:**
```elixir
# Option A: Use supervision tree restructuring
# Separate long-running services from one-time initialization

# Option B: Make steps idempotent (already partially done)
# MigrationRunner uses Ecto's built-in migration tracking

# Option C: Use :one_for_one for independent stages
# But requires explicit dependency management
```

### Problem: Very Low Restart Tolerance
```elixir
max_restarts: 1, max_seconds: 5  # BootSupervisor
max_restarts: 1, max_seconds: 15 # start_link
```

**Issue:** A single transient failure (e.g., SD card hiccup during initdb) kills the entire boot sequence permanently.

**BEAM Fix:**
```elixir
# Increase restart tolerance for transient failures
max_restarts: 3, max_seconds: 60

# Or use exponential backoff via a custom supervisor
# that tracks restart history and delays restarts
```

---

## 2. Process Linking Gaps

### Problem: Task.Supervisor.async_nolink Without Proper Monitoring
**Location:** Multiple step modules

```elixir
# In Pg.Initializer:
%{ref: ref} = Task.Supervisor.async_nolink(task_supervisor, fn -> ... end)
```

Using `async_nolink` means the parent doesn't crash if the task crashes. The module handles `:DOWN` messages, but there's a race condition:

**Issue:** If the GenServer crashes between spawning the task and receiving the result, the task continues running orphaned. On restart, a new task starts—now two initdb processes might run simultaneously.

**BEAM Fix:**
```elixir
# Option A: Use Process.link + trap_exit for explicit crash propagation
Process.flag(:trap_exit, true)
{:ok, pid} = Task.Supervisor.start_child(task_supervisor, fn -> ... end)
Process.link(pid)

# Option B: Track task state externally (e.g., file lock)
# Option C: Use async with timeout and explicit cleanup
```

---

## 3. Daemon Crash Recovery Limitations

### Problem: Fixed Restart Limit Without Backoff
**Location:** `lib/platform/storage/pg/daemon.ex:75-100`

```elixir
def on_msg({:EXIT, daemon_pid, reason}, %{daemon_restart_count: restart_count} = state)
    when restart_count < 3 do
  Process.send_after(self(), :start, :timer.seconds(2))
  {:noreply, %{state | daemon_restart_count: restart_count + 1}}
end
```

**Issues:**
1. Fixed 2-second delay—no exponential backoff for persistent problems
2. Counter never resets—once at 3 restarts, even a healthy daemon can't recover from future crashes
3. No distinction between crash types (resource exhaustion vs config error vs hardware)

**BEAM Fix:**
```elixir
# Exponential backoff with jitter
defp restart_delay(attempt) do
  base_delay = :timer.seconds(2)
  max_delay = :timer.minutes(5)
  jitter = :rand.uniform(1000)
  min(base_delay * :math.pow(2, attempt) + jitter, max_delay) |> trunc()
end

# Reset counter on successful operation
def on_msg(:wait_for_ready, state) do
  # After successful health check:
  {:noreply, %{state | daemon_restart_count: 0}}  # Reset on success
end

# Distinguish crash types
def on_msg({:EXIT, pid, {:shutdown, :resource_exhausted}}, state) do
  # Wait longer, cleanup resources
end
def on_msg({:EXIT, pid, {:config_error, _}}, state) do
  # Log and stop—no point retrying
end
```

---

## 4. Health Check Single Point of Failure

### Problem: Health Check Relies on Single Query
**Location:** `lib/platform/tools/postgres/lifecycle.ex:312-319`

```elixir
def server_running?(opts \\ []) do
  pg_port = Keyword.get(opts, :pg_port, 5432)
  {_, status} = run_pg("psql", ["-U", @postgres_user, "-h", @pg_host, "-p", "#{pg_port}", "-c", "SELECT 1"])
  status == 0
end
```

**Issues:**
1. Single query success doesn't mean database is healthy
2. No connection pool health validation
3. No check for disk space, WAL accumulation, or replication lag

**BEAM Fix:**
```elixir
def health_check(opts) do
  with :ok <- check_server_responding(opts),
       :ok <- check_disk_space(opts),
       :ok <- check_wal_size(opts),
       :ok <- check_active_connections(opts) do
    :ok
  end
end

# Periodic health checks via :timer.send_interval
def on_init(opts) do
  :timer.send_interval(:timer.seconds(30), :health_check)
  # ...
end
```

---

## 5. Shared Memory Cleanup Race Conditions

### Problem: Non-Atomic Cleanup
**Location:** `lib/platform/tools/postgres/shared_memory.ex` (not shown but referenced)

```elixir
Postgres.cleanup_stale_shared_memory(pg_data_dir)
```

**Issue:** Cleanup checks if PID is alive, then removes shared memory. Between check and removal, a new PostgreSQL might start using that memory.

**BEAM Fix:**
```elixir
# Use file locks for coordination
defp with_pg_lock(pg_dir, fun) do
  lock_file = Path.join(pg_dir, ".pg_startup.lock")

  case :file.open(lock_file, [:write, :exclusive]) do
    {:ok, fd} ->
      try do
        fun.()
      after
        :file.close(fd)
        File.rm(lock_file)
      end
    {:error, :eexist} ->
      {:error, :locked}
  end
end
```

---

## 6. Dynamically Created Modules Not Supervised

### Problem: Module.create Without Cleanup
**Location:** `lib/platform/app/drive/boot_supervisor.ex:63-70`

```elixir
repo_module_content = quote do
  use Ecto.Repo, otp_app: :platform, adapter: Ecto.Adapters.Postgres
end
Module.create(repo_name, repo_module_content, Macro.Env.location(__ENV__))
```

**Issues:**
1. Module created at supervisor init—if supervisor restarts, module is recreated (harmless but wasteful)
2. No cleanup when drive is ejected—module remains in memory
3. Application.put_env with typo: `:platfrom` instead of `:platform`

**BEAM Fix:**
```elixir
# Check if module exists before creating
unless Code.ensure_loaded?(repo_name) do
  Module.create(repo_name, repo_module_content, Macro.Env.location(__ENV__))
end

# Fix typo
Application.put_env(:platform, repo_name, &1)  # Not :platfrom

# Consider using a registry + GenServer wrapper instead of dynamic modules
```

---

## 7. Timeout Cascades

### Problem: Nested Timeouts Don't Account for Children
**Location:** Multiple supervisors

```elixir
# BootSupervisor: shutdown 180s for PgServer
{@pg_daemon, ...} |> exit_takes(180_000)

# But Daemon's internal timeout:
use GracefulGenServer, timeout: :timer.minutes(3)  # Also 180s
```

**Issue:** If PgServer shutdown takes 180s, and it has children with their own 180s timeouts, total shutdown can exceed parent's patience, causing brutal_kill.

**BEAM Fix:**
```elixir
# Calculate nested timeouts properly
@daemon_timeout :timer.minutes(3)
@child_shutdown @daemon_timeout + :timer.seconds(30)  # Buffer

# Or use infinite shutdown with monitoring
def exit_takes_with_monitor(spec, timeout) do
  spec
  |> Supervisor.child_spec(shutdown: :infinity)
  |> Map.put(:monitor_shutdown, timeout)
end
```

---

## 8. No Circuit Breaker for External Dependencies

### Problem: Retries Without Limits on initdb/psql
**Location:** `lib/platform/tools/postgres/lifecycle.ex:63-138`

```elixir
def initialize(opts, retries \\ 5) do
  # ...
  initialize(opts, retries_left)  # Recursive retry
end
```

**Issue:** If the underlying disk is failing, we retry 5 times with no backoff, potentially making things worse. No circuit breaker to stop attempts entirely.

**BEAM Fix:**
```elixir
# Circuit breaker pattern
defmodule Platform.CircuitBreaker do
  use GenServer

  def call(name, fun, opts \\ []) do
    case get_state(name) do
      :open -> {:error, :circuit_open}
      :half_open -> try_call(name, fun, opts)
      :closed -> try_call(name, fun, opts)
    end
  end

  defp try_call(name, fun, opts) do
    case fun.() do
      {:error, _} = error ->
        record_failure(name)
        error
      result ->
        record_success(name)
        result
    end
  end
end

# Usage
CircuitBreaker.call(:pg_init, fn ->
  Postgres.initialize(opts)
end)
```

---

## 9. State Machine Complexity Hidden in GenServer

### Problem: Implicit State Transitions
**Location:** `lib/platform/storage/pg/daemon.ex`

The daemon has implicit states (starting → waiting → ready → crashed → restarting) tracked via message flow, not explicit state machine.

**Issue:** Hard to reason about valid transitions. What happens if `:wait_for_ready` arrives when daemon already crashed?

**BEAM Fix:**
```elixir
# Use explicit state machine (gen_statem or state pattern)
defmodule Platform.Storage.Pg.Daemon do
  use GenStateMachine, callback_mode: [:handle_event_function, :state_enter]

  def handle_event(:enter, _old, :starting, data) do
    # Start daemon
    {:next_state, :waiting_for_ready, data}
  end

  def handle_event(:enter, _old, :waiting_for_ready, data) do
    # Begin health checks
    {:next_state, :ready, data, [{:state_timeout, 60_000, :timeout}]}
  end

  def handle_event(:info, {:EXIT, pid, reason}, :ready, %{daemon_pid: pid} = data) do
    # Explicit crash handling
    {:next_state, :crashed, %{data | crash_reason: reason}}
  end
end
```

---

## 10. Missing Telemetry/Observability

### Problem: Only Logging, No Metrics
**Location:** All modules use `log()` but no telemetry events

**Issue:** Can't monitor:
- PostgreSQL startup latency histogram
- Crash frequency rates
- Retry counts
- Health check failures

**BEAM Fix:**
```elixir
# Add telemetry events
:telemetry.execute(
  [:platform, :postgres, :daemon, :start],
  %{duration: duration, attempt: attempt},
  %{device: device, port: port}
)

:telemetry.execute(
  [:platform, :postgres, :daemon, :crash],
  %{count: 1},
  %{device: device, reason: reason}
)

# Attach handlers for metrics collection
:telemetry.attach_many(
  "platform-postgres-metrics",
  [
    [:platform, :postgres, :daemon, :start],
    [:platform, :postgres, :daemon, :crash]
  ],
  &Platform.Metrics.handle_event/4,
  nil
)
```

---

## Summary: Priority Fixes

| Priority | Issue | Fix |
|----------|-------|-----|
| **High** | Typo in `Application.put_env(:platfrom,...)` | Simple fix: `:platform` |
| **High** | Low restart tolerance | Increase `max_restarts` |
| **High** | No backoff on daemon restart | Implement exponential backoff |
| **Medium** | Task race conditions | Use proper linking or file locks |
| **Medium** | Health check insufficiency | Multi-factor health checks |
| **Medium** | Implicit state machine | Consider gen_statem |
| **Low** | No telemetry | Add :telemetry events |
| **Low** | Dynamic module cleanup | Check existence before create |

---

## Appendix: Module Reference

| Module | Type | Timeout | Purpose |
|--------|------|---------|---------|
| `Platform.App.DeviceSupervisor` | Supervisor | - | Top-level USB drive management |
| `Platform.App.DatabaseSupervisor` | Supervisor | 5min | Internal database stages |
| `Platform.App.Drive.BootSupervisor` | Supervisor | - | Per-drive boot sequence |
| `Platform.Storage.Pg.Initializer` | Step | 1min | Run initdb |
| `Platform.Storage.Pg.Daemon` | Stage | 3min | Run postgres daemon |
| `Platform.Storage.Pg.DbCreator` | Step | 1min | Create database |
| `Platform.Storage.Repo.Starter` | Stage | 3min | Start Ecto.Repo |
| `Platform.Storage.Repo.MigrationRunner` | Step | 3min | Run migrations |
| `Platform.Tools.Postgres` | Facade | - | Delegates to submodules |
| `Platform.Tools.Postgres.Lifecycle` | Module | - | Server lifecycle ops |
| `Platform.Tools.Postgres.Database` | Module | - | SQL/DB operations |
| `Platform.Tools.Postgres.Permissions` | Module | - | uid/gid/chmod |
| `Platform.Tools.Postgres.SharedMemory` | Module | - | POSIX/SysV cleanup |
