# Changelog

## 0.2.0 — 2026-06-12

Major rework: from "outbox with unbounded retries" to a full offline-first
engine. Persisted records from 0.1.x deserialize unchanged.

### Added
- **Pull replication**: `SyncCollection<T>` (fetchPage/applyPage), engine-owned
  watermarks (`WatermarkStore`, `StorageWatermarkStore`), pagination loop,
  page bounds, per-collection progress events. `sync()` now pushes then pulls.
- **`SyncOutbox`** write API: crash-safe `submit(TaskDraft)` (actions first,
  task as commit marker), `appendAction`, `resetFailedActions`,
  `collectGarbage` (orphan sweep), task/action lookups.
- **`TaskDraft` / `ActionHandle`** builder: auto IDs, auto idempotency keys,
  sequential chaining by default, explicit dependency graphs.
- **`$ref:<actionId>:<path>` placeholders** resolved by the engine into
  payloads; ref targets are implicit dependencies (cross-task supported).
- **Typed errors**: `RetryableSyncException`, `PermanentSyncException`,
  `ConflictSyncException`; `lastError` persisted on actions and tasks.
- **`RetryPolicy`**: bounded attempts + exponential backoff; escalation to
  `failedPermanent` (v1 retried forever with no delay).
- **Typed event stream** `SyncEngine.events` (`SyncEvent` hierarchy) and a
  `SyncReport` return value; legacy `statusStream` now carries real counters.
- Multi-dependency actions (`QueueAction.dependencies`); `dependsOn` kept as
  a deprecated single-value view.
- Injectable `Clock`; explicit `start()`/`stop()` lifecycle (constructor no
  longer subscribes to connectivity).
- Missed-sync coalescing: `sync()` during a run merges into a follow-up run.
- Empty-task guard: a task with no actions past a grace period fails loudly
  instead of being vacuously marked synced.
- In-memory implementations for every port + a full test suite.

### Changed
- `QueueService` interface gained `getAllTasks()` and `clearTasks()`.
- `sync()` returns `SyncReport` (was `void`).
- An offline `sync()` reports `skippedOffline` instead of silently returning.

### Migration notes (0.1.x → 0.2.0)
- Call `await engine.start()` after registering processors/collections —
  connectivity reaction is no longer automatic on construction.
- Implement the two new `QueueService` methods.
- Replace hand-built `QueueTask`/`QueueAction` enqueueing with
  `outbox.submit(TaskDraft...)`.
- Replace "fetch remote data" pseudo-actions with registered
  `SyncCollection`s; keep a no-op processor for the old action type so
  queues persisted by previous app versions complete cleanly.

## 0.1.0

Initial extraction: queue models, storage/connectivity interfaces, multi-pass
sync engine with single-parent dependencies, foreground
`BackgroundSyncManager`.
