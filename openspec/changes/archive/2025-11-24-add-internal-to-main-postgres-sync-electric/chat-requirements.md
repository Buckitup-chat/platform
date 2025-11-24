# Chat-side Requirements: ElectricSQL Sync for Platform

This document lists requirements for the Chat project to provide ElectricSQL-based Postgres synchronization used by Platform.

## API Surface (to be provided by Chat)
- Start: `start_sync(opts)` → {:ok, pid | ref} | {:error, reason}
- Stop: `stop_sync(pid | ref)` → :ok
- Status: `status(pid | ref)` → %{state: :active|:done|:error, progress: float | nil, last_error: term | nil}
- Telemetry: emit lifecycle and error events with identifiers (source/target repo names)

## Inputs (opts)
- `source_repo`: module for InternalDb (e.g., `Chat.Db.InternalDb` or Repo alias)
- `target_repo`: module for MainDb (e.g., `Chat.Db.MainDb` or Repo alias)
- `schemas`: list of schemas to replicate (initially `[:users]`)
- `tables`: optional list of {schema, table} to narrow scope

## Behavioral Requirements
- In-process, local-only operation; no network calls
- One-way Internal→Main; no writes back to Internal via this pipeline
- Idempotent apply on target; safe on repeated invocations within the copier
- Bounded resource usage; avoid starving the copier process
- Clear termination semantics suitable for being called inside a stage (start→finish)

## Observability
- Emit telemetry events for start/finish, error, and minimal progress
- Provide counters for rows replicated and elapsed time

## Security
- No external credentials/TLS required (local-only)
- Ensure sensitive data never appears in logs/telemetry

## Conventions
- Safe to call `start_sync` once per copier run; return existing ref if already active
- Accept repo modules and schema/table lists directly (no URLs/publications/slots)

## Deliverables
- Minimal reference implementation wired to ElectricSQL
- Mockable interface for Platform tests
- Documentation with configuration examples
