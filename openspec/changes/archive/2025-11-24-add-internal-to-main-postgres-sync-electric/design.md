## Context
Platform currently performs copy/mirror operations between `InternalDb` and `MainDb` using Chat Db utilities. We need an in-process, local Postgres-level synchronization from Internal→Main, delegated to ElectricSQL (provided by Chat) and orchestrated entirely on-device.

## Goals / Non-Goals
- Goals: one-way Internal→Main sync, local-only, observable, minimal coupling
- Non-Goals: bidirectional sync, schema design changes, client-facing APIs beyond status

## Decisions
- One-way authoritative source: InternalDb; MainDb is replica for this pipeline
- Use ElectricSQL in-process for row-level sync; Platform orchestrates lifecycle only
- Run the sync within `Platform.Storage.InternalToMain.Copier` lifecycle:
  - Start immediately after bootstrap copy completes
  - Stop when the copier stage completes (status flips when copier finishes)
- Initial scope: `users` schema only (tables within the `users` schema)

## Risks / Trade-offs
- Coupling sync lifetime to copier stage execution
- Local IO throughput variance (SD→USB) may affect completion time
- Resource contention (CPU/IO) with other on-device tasks during copy+sync

## Migration Plan
1) Keep current copier flow to bootstrap data
2) Invoke in-process ElectricSQL sync from within the copier after bootstrap
3) Gate rollout via feature flag if needed; measure completion timing
4) Optionally deprecate periodic `MainReplicator` if redundant

## Open Questions
- None for initial scope (schema: `users`); expand scopes later if needed
