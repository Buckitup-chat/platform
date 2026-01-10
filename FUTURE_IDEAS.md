# Future Ideas

## DB waiting UI

When PostgreSQL (and therefore `Chat.Repo`) is not yet ready during boot, the UI currently allows interactions that can crash due to missing Repo.

Idea:

- Provide an alternative UI state that detects DB readiness and shows a “Starting database…” screen.
- Disable login/user registration events until DB is reachable.
- Optionally provide a retry/backoff indicator and a link to `/db_log` for diagnostics.

Implementation sketch:

- Add a small “DB readiness” check (e.g. `Platform.Tools.Postgres.server_running?/1` or an Ecto repo ping) exposed to the LiveView.
- In `ChatWeb.MainLive.*` components, gate DB-dependent actions based on readiness.
- Keep the UX consistent for both internal boot and USB main DB switch flows.
