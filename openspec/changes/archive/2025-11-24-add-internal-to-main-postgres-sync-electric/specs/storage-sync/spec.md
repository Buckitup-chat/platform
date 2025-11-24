## ADDED Requirements

### Requirement: Internal→Main Postgres Sync via ElectricSQL (Local, In-Process)
The system SHALL provide resilient, one-way, local synchronization from `InternalDb` to `MainDb` at the Postgres level using ElectricSQL (provided by Chat), executed in-process and starting immediately after the initial internal→main copy completes.

#### Scenario: Start and run within copier lifecycle
- **WHEN** `InternalToMain.Copier` finishes bootstrapping data
- **THEN** the system SHALL run an in-process sync from `InternalDb` to `MainDb` within the copier process
- **AND** the sync SHALL stop and report completion when the copier stage finishes

#### Scenario: Local-only operation
- **WHEN** the sync runs
- **THEN** no network communication SHALL be used; all operations occur on-device (e.g., SD→USB)

#### Scenario: One-way replication policy
- **WHEN** conflicts arise
- **THEN** the pipeline SHALL treat `InternalDb` changes as the source of truth and MUST NOT write Main→Internal through this pipeline

#### Scenario: Status exposure
- **WHEN** status is requested by the platform
- **THEN** the system SHALL expose sync state (e.g., active|done|error) via logging/telemetry and a simple status function, with status flipping to done when the copier completes

#### Scenario: Scoped table replication (users schema)
- **WHEN** replicating tables
- **THEN** the system SHALL replicate only the `users` schema (or configured subset thereof)

#### Scenario: Graceful stop
- **WHEN** switching away from main, shutting down, or disabling the feature
- **THEN** the system SHALL stop the sync gracefully and clean up connections
