# sync_it

**Offline-first synchronization engine for Dart/Flutter apps.**

A pure-Dart package (no Flutter, no Hive, no Dio dependencies) that gives any
app two things:

1. **Push — a persistent outbox.** Work created offline (orders, payments,
   customer edits) is stored as dependency-ordered tasks and replayed against
   the server when connectivity returns, with bounded retries, exponential
   backoff, typed failure classification, and crash-safe enqueueing.
2. **Pull — collection replication.** Server data (catalogues, customer
   lists) is mirrored into local storage with per-collection watermarks,
   delta filters, pagination, and live progress events — the host app only
   writes two callbacks per collection.

Everything observable is published on **one typed event stream**, so a sync
screen is a thin projection with no sync logic of its own.

```
            ┌──────────────────────── HOST APP ────────────────────────┐
            │  UI / cubits          repositories          DI / startup │
            │      │ listen to           │ submit drafts        │ start│
            ▼      ▼                     ▼                      ▼      │
┌──────────────────────────────────── sync_it ─────────────────────────────────┐
│                                                                              │
│   SyncEngine.events  ◄──  SyncEngine  ──►  sync() = drain outbox + pull      │
│   (SyncEvent stream)          │                                              │
│                  ┌────────────┼──────────────┐                               │
│                  ▼            ▼              ▼                               │
│             SyncOutbox   OutboxDrainer  CollectionSyncer                     │
│             (write API)  (push replay)  (pull loop + watermark)              │
│                  │            │              │                               │
└──────────────────┼────────────┼──────────────┼───────────────────────────────┘
                   ▼            ▼              ▼
        QueueService/ActionService      WatermarkStore        SyncConnectivity
        (host implements: Hive, SQL…)   (host or default)     (host implements)
```

---

## Table of contents

1. [Core concepts](#core-concepts)
2. [Integration guide — wiring sync_it into a new app](#integration-guide)
3. [The outbox: queuing offline work](#the-outbox)
4. [`$ref` placeholders: using one action's server result in another](#ref-placeholders)
5. [Processors: executing queued work](#processors)
6. [Pull collections: replicating server data](#pull-collections)
7. [Events: driving a sync UI](#events)
8. [Retry, errors, and failure surfacing](#retry-and-errors)
9. [Crash safety & data integrity model](#crash-safety)
10. [Sync triggers](#sync-triggers)
11. [Hard contracts (read before shipping)](#hard-contracts)
12. [Testing your integration](#testing)
13. [API quick reference](#api-quick-reference)

---

## Core concepts

| Concept | Type | What it is |
|---|---|---|
| **Task** | `QueueTask` | One unit of offline business work (e.g. "checkout this sale"). Groups actions. Statuses: `pendingSync → synced / syncFailed`. |
| **Action** | `QueueAction` | One executable step of a task (e.g. `CREATE_ORDER`). Has dependencies, a payload, an idempotency key, a retry count, a persisted `result`, and `lastError`. Statuses: `pending → done / retryPending / failedPermanent`. |
| **Outbox** | `SyncOutbox` | The only write API for queueing work: `submit(TaskDraft)`, `appendAction`, `resetFailedActions`, lookups. |
| **Processor** | `IActionProcessor` | Host-implemented executor for one action type. Receives the action (payload already `$ref`-resolved) and returns the server result as a plain map. |
| **Collection** | `SyncCollection<T>` | Host-declared pull replication unit: `fetchPage` + `applyPage`. The engine owns the watermark, the pagination loop, progress, and bounds. |
| **Watermark** | `WatermarkStore` | Per-collection "last successful pull" instant. Advanced only after a fully successful pull. |
| **Engine** | `SyncEngine` | Orchestrates everything: `sync()` = drain outbox (push) then pull collections, with connectivity awareness, coalescing, and events. |

---

## Integration guide

A complete integration is **four adapters + your business processors and
collections**. Steps, in order:

### Step 1 — Implement the storage ports

`QueueService` (tasks) and `ActionService` (actions) over your local store.
Records are persisted via `toMap()` / `fromMap()` (plain JSON-safe maps).

```dart
class MyQueueService implements QueueService {
  // enqueue / getPendingTasks / getAllTasks / updateTask / removeTask / clearTasks
}
class MyActionService implements ActionService {
  // addAction / removeAction / updateAction / getActionsForQueue / getAllActions / clearActions
}
```

**Rules your implementation MUST follow:**

- `addAction` / `enqueue` **must throw** on write failure. A silently dropped
  enqueue is silently lost business data; the engine and callers rely on the
  exception to surface it.
- Read methods must **quarantine corrupt records** (skip + log the single bad
  record), never return an empty list because one record failed to parse —
  that would make the whole queue invisible.
- Return results **oldest first** (`createdAt` ascending).
- Deep-convert nested maps to `Map<String, dynamic>` when reading (a JSON
  round-trip is the simple way).

*(A Hive-backed reference shape: `HiveQueueService` / `HiveActionService`
that store each record as a plain JSON map and quarantine corrupt reads.)*

### Step 2 — Implement connectivity

```dart
class MyConnectivity implements SyncConnectivity {
  Future<bool> get isOnline => ...;          // actual internet, not just radio
  Stream<bool> get onConnectivityChanged => ...;
}
```

### Step 3 — Implement (or borrow) a watermark store

Use `StorageWatermarkStore` over any `SyncStorage<String>`, or implement
`WatermarkStore` directly (ISO-8601 timestamps keyed by collection name).
If you skip this, the engine uses `InMemoryWatermarkStore` and every pull is
a **full** pull after app restart.

### Step 4 — Construct, register, start

```dart
final engine = SyncEngine(
  connectivity: myConnectivity,
  queueService: myQueueService,
  actionService: myActionService,
  watermarks: myWatermarkStore,
  retryPolicy: const RetryPolicy(          // all optional, sane defaults
    maxAttempts: 5,
    initialBackoff: Duration(seconds: 5),
    maxBackoff: Duration(minutes: 10),
  ),
);

// Push side: one processor per action type.
engine.registerProcessor(saleOrderProcessor);
engine.registerProcessor(customerProcessor);

// Pull side: one collection per replicated dataset.
engine.registerCollection(customersCollection);
engine.registerCollection(productsCollection);

// AFTER everything is registered: react to connectivity restoration.
await engine.start();
```

Construction has **no side effects** — nothing happens until `start()` or
`sync()`. Register the engine and `engine.outbox` in your DI container;
repositories depend on `SyncOutbox`, UIs on `SyncEngine`.

### Step 5 — Use it

```dart
final report = await engine.sync();   // push everything, then pull everything
await engine.sync(pull: false);       // push only
await engine.sync(push: false, collections: {'products'});  // one collection
```

---

## The outbox

Repositories queue offline work with a `TaskDraft` — IDs, dependency wiring,
idempotency keys, and timestamps are generated for you:

```dart
// A sale checked out offline: three steps, executed strictly in order
// when the device is back online.
final draft = TaskDraft(
  type: 'SALE_ORDER.createAndCheckout',
  payload: {'tempId': tempOrderId},          // task metadata, not executed
);
final create = draft.addAction(type: 'CREATE_ORDER', payload: orderJson);
final open = draft.addAction(
  type: 'OPEN_ORDER',
  payload: {'orderId': create.ref('id')},    // ← server ID, resolved later
);
draft.addAction(type: 'VALIDATE_ALLOCATIONS',
    payload: {'openOrder': open.ref()});     // ← whole result map

await outbox.submit(draft);                  // crash-safe, atomic-by-ordering
```

- Steps **chain sequentially by default** (each depends on the previous one).
  Pass `dependsOn: [...]` (handles or raw action IDs — including IDs from
  *other* tasks) or `chainAfterPrevious: false` for explicit graphs.
- `submit` **throws** if the draft has no actions or storage fails —
  repositories must surface that to the user as a failure (`Left(Failure)` in
  an Either-style app). Never swallow it.
- Append later steps to a live task (e.g. a payment taken after checkout):

```dart
await outbox.appendAction(
  taskId: task.id,
  type: 'CREATE_PAYMENT',
  payload: {'orderId': RefResolver.ref(openActionId, 'id'), 'payment': data},
  dependsOn: [lastPaymentOrValidateActionId],
);
```

- Look things up without touching storage types:
  `findTaskWhere`, `findActionWhere`, `actionsForTask`, `pendingTasks`,
  `allTasks`, `pendingTaskCount`.
- Maintenance: `resetFailedActions()` (revive `failedPermanent`/`retryPending`
  with a fresh retry budget), `collectGarbage()` (sweep orphans from
  interrupted submits — the engine runs this automatically each sync),
  `clear()` (destructive, for explicit user "clear cache" flows only).

## Ref placeholders

The hard problem in offline queues: *step B needs the server ID that step A
will only receive when it eventually runs.* sync_it solves this declaratively:

- Any **string** payload value of the form `$ref:<actionId>:<path>` is
  replaced, immediately before the processor runs, with the value at `path`
  inside that action's persisted result map. Dots traverse
  (`$ref:abc:customer.id`); omitting the path substitutes the whole result.
- Build them with `handle.ref('id')` (within a draft) or
  `RefResolver.ref(actionId, 'id')` (cross-task).
- **Every `$ref` target is automatically a dependency** — the engine will not
  run an action until all referenced actions are `done`, and it keeps
  completed actions alive in storage for as long as something still
  references them.
- Refs work **across tasks**: an offline-created order can reference the
  queued customer-create action from a different task; the engine sequences
  both and patches the real customer ID in.
- An unresolvable ref (missing path, deleted dependency) fails the action
  permanently with a diagnostic `lastError` — it's a programming/data error,
  not a transient one.

## Processors

One class per action type — the only place business meets the engine:

```dart
class SaleOrderProcessor implements IActionProcessor {
  @override
  String get actionType => 'CREATE_ORDER';

  @override
  Future<Map<String, dynamic>> process(
    QueueAction action,                       // payload already $ref-resolved
    Map<String, dynamic> previousResults,     // results by action ID (legacy)
  ) async {
    final result = await api.createOrder(
      body: action.payload,
      idempotencyKey: action.idempotencyKey,  // ← REQUIRED, see contracts
    );
    return result.toJson();   // plain JSON map — persisted as the result
  }
}
```

Processor rules:

- **Classify failures by exception type** (see [Retry & errors](#retry-and-errors)).
  Anything else thrown is treated as retryable.
- **Never return a fake success.** Returning normally marks the action
  `done` forever. If you can't do the work yet (not authenticated, missing
  precondition), throw `RetryableSyncException`.
- The returned map is JSON round-tripped and persisted; later actions read it
  via `$ref`. Keep it plain data.
- Read inputs from `action.payload` (with refs), not by scanning
  `previousResults` — the scan API exists only for pre-`$ref` compatibility.

Register one processor instance under several action types with a thin
wrapper if they share implementation (a small `IActionProcessor` whose
`actionType` differs but that delegates to one shared handler).

## Pull collections

Declare *what* to replicate; the engine owns *how*:

```dart
final customers = SyncCollection<CustomerModel>(
  name: 'customers',                 // watermark key + event name
  firstPage: 0,                      // your API's first page index
  maxPages: 500,                     // runaway-API bound (default 500)
  fetchPage: (since, page) async {
    // `since` is the watermark — null on first pull (fetch everything).
    final res = await api.getCustomers(updatedSince: since, page: page);
    return PullPage(
      items: res.customers,
      hasMore: res.customers.length >= pageSize,
      totalCount: res.totalCount,    // optional — enables progress fractions
    );
  },
  applyPage: (items) => local.upsertCustomers(items),  // MUST be idempotent
);
engine.registerCollection(customers);
```

Engine-owned semantics:

- The watermark candidate is captured **before** fetching, so rows updated
  mid-pull are re-fetched next time instead of slipping through the gap.
- The watermark advances **only after a fully successful pull**; a failed or
  page-bound-truncated pull retries the same window on the next sync.
- Pages are applied as they arrive (progress events fire per page).
- Collections are pulled **after** the outbox drains, so locally created
  records reach the server before the pull mirrors them back.
- Per-collection failures are isolated: one broken collection doesn't stop
  the others; it lands in `SyncReport.pullErrors`.

## Events

Subscribe once; render everything:

```dart
engine.events.listen((event) {
  switch (event) {
    case SyncStarted(:final pendingTasks): ...
    case SyncCompleted(:final report): ...
    case TaskSyncStarted(:final task): ...
    case TaskSynced(:final task): ...
    case TaskSyncFailed(:final task, :final error): ...
    case ActionSynced(:final action): ...
    case ActionSyncFailed(:final action, :final error, :final willRetry, :final isConflict): ...
    case CollectionPullStarted(:final collection): ...
    case CollectionPullProgress(:final collection, :final itemsApplied, :final totalCount): ...
       // event.fraction → 0..1 progress when the server reports a total
    case CollectionPullCompleted(): ...
    case CollectionPullFailed(:final collection, :final error): ...
  }
});
```

A coarse `engine.statusStream` (`SyncStatusEvent`: `isSyncing`,
`totalPending`, `syncedCount`, `failedCount`) is kept for spinner-and-counter
UIs. `sync()` also returns a `SyncReport` summarizing the run.

## Retry and errors

Processors speak to the engine through three exception types:

| Throw | Meaning | Engine behavior |
|---|---|---|
| `RetryableSyncException` (or any unknown error) | Transient: timeout, 5xx, offline-ish | `retryPending`, exponential backoff, re-attempted until `RetryPolicy.maxAttempts`, then escalated to `failedPermanent` |
| `PermanentSyncException` | Will never succeed: validation 4xx, deleted resource, malformed payload | `failedPermanent` immediately |
| `ConflictSyncException` | Remote state diverged (version mismatch, duplicate) | `failedPermanent` + `ActionSyncFailed(isConflict: true)` so UIs can offer resolution |

Failure handling guarantees:

- Every failure message is **persisted** on the action (`lastError`) and the
  task — sync UIs can show *why*, not just *that*, something failed.
- Backoff is wall-clock based (`lastAttemptAt` + policy), so repeated `sync()`
  calls do not hammer a failing endpoint.
- `failedPermanent` work is never retried automatically. The user revives it
  explicitly via `outbox.resetFailedActions()`.
- A task is `syncFailed` only for permanent failures or corruption; tasks
  with only transient failures stay `pendingSync` and heal on later syncs.

## Crash safety

The integrity model, so you can reason about power-loss at any instant:

- **Commit ordering**: `submit` writes all actions first, then the task. The
  task record is the commit marker. A crash mid-submit leaves orphan actions
  (harmless, invisible) which `collectGarbage` sweeps after an age threshold
  (default 1 hour, engine runs it every sync).
- **Empty-task guard**: a task with zero actions older than a grace period
  (default 10 min) is failed loudly (`syncFailed`, "enqueue was interrupted")
  — it is *never* vacuously marked synced.
- **Coalescing**: `sync()` during a running sync never drops the request — it
  is merged into an immediate follow-up run; the shared future completes when
  everything is done. Work enqueued mid-sync is therefore always picked up.
- **Cleanup**: fully-synced tasks and their actions are deleted, except
  `done` actions that other pending actions still reference (cross-task
  refs); those are removed by a later sweep once nothing depends on them.
- **Persisted-format stability**: status enum strings and record fields are
  backward compatible — v1 records (single `dependsOn`, no `lastError`)
  deserialize cleanly, and v2 writes keep a legacy `dependsOn` field for
  rollback safety.

## Sync triggers

| Trigger | Provided by | Notes |
|---|---|---|
| Connectivity restored | `engine.start()` | Subscribes to `SyncConnectivity.onConnectivityChanged`; full `sync()` on regain. |
| Manual / app event | host | `engine.sync(...)` from a cubit/controller — on login, or on app-resume via a lifecycle observer. |
| Foreground periodic | `BackgroundSyncManager` + `IBackgroundProcessor` | In-process `Timer`-based scheduler. **Runs only while the app is alive** — it is not an OS background task. |
| OS background | host | Pair with `workmanager`/BGTaskScheduler on the app side; the callback boots a minimal DI and calls `engine.sync()`. sync_it stays pure Dart on purpose. |

## Hard contracts

Things that are **your responsibility** and will bite if skipped:

1. **Idempotency end-to-end.** Every action carries an `idempotencyKey`
   (stable across retries). Your processor MUST transmit it (e.g. an
   `Idempotency-Key` header) and your server MUST deduplicate on it.
   Without this, a request that times out *after* the server committed will
   be replayed and **duplicate the order/payment**. The engine cannot solve
   this client-side — it can only guarantee the key is stable and available.
2. **`applyPage` is idempotent (upsert).** Failed pulls re-apply pages.
3. **Storage adapters throw on write failure and quarantine corrupt reads**
   (see Step 1).
4. **Surface enqueue failures to the user.** `outbox.submit` throwing means
   the sale was NOT queued. Return a failure; never log-and-continue.
5. **Processors never return success for work not done** — throw
   `RetryableSyncException` instead.
6. **Register everything before `start()`**, so a connectivity-triggered sync
   never runs with missing processors (a missing processor permanently fails
   the action, by design — silent stalls are worse).
7. **Don't reuse collection names** — the name is the watermark key and the
   event identity.

## Testing

The package ships in-memory implementations of every port:
`InMemoryQueueService`, `InMemoryActionService`, `InMemoryWatermarkStore`,
`InMemorySyncStorage`. A full engine harness needs ~20 lines:

```dart
final engine = SyncEngine(
  connectivity: fakeConnectivity,         // your 10-line fake
  queueService: InMemoryQueueService(),
  actionService: InMemoryActionService(),
  watermarks: InMemoryWatermarkStore(),
  clock: fakeClock.call,                  // inject time → deterministic backoff
);
```

Inject a `Clock` (`DateTime Function()`) to test backoff windows, GC ages,
and grace periods without real waiting. See `test/` in this package for the
canonical patterns: dependency chains, cross-task refs, retry escalation,
coalescing, watermark behavior, and the crash-safety regressions.

## API quick reference

```text
SyncEngine
  ctor(connectivity, queueService, actionService,
       {retryPolicy, watermarks, clock, maxPasses, emptyTaskGrace, orphanActionAge})
  registerProcessor(IActionProcessor)        registerCollection(SyncCollection)
  start() / stop() / dispose()
  sync({push = true, pull = true, collections}) → SyncReport
  pullCollection(name) → PullResult
  events → Stream<SyncEvent>                 statusStream → Stream<SyncStatusEvent>
  isSyncing / collectionNames / outbox / now()

SyncOutbox
  submit(TaskDraft) → SubmittedTask          appendAction({taskId, type, payload, dependsOn})
  findTaskWhere / findActionWhere / actionsForTask
  allTasks / pendingTasks / allActions / pendingTaskCount
  resetFailedActions() → int                 collectGarbage({olderThan}) → int
  clear()

TaskDraft(type, {payload, id})
  addAction({type, payload, dependsOn, chainAfterPrevious, idempotencyKey}) → ActionHandle
ActionHandle.ref([path])                     RefResolver.ref(actionId, [path])

RetryPolicy({maxAttempts, initialBackoff, multiplier, maxBackoff})
SyncException → RetryableSyncException | PermanentSyncException | ConflictSyncException

SyncCollection<T>({name, fetchPage, applyPage, firstPage, maxPages})
PullPage<T>({items, hasMore, totalCount})
WatermarkStore → StorageWatermarkStore(SyncStorage<String>) | InMemoryWatermarkStore

Host-implemented ports:
  QueueService · ActionService · SyncConnectivity · SyncStorage<T>
  IActionProcessor · IBackgroundProcessor
```

---

### Reference integration

A typical host app supplies these pieces around sync_it (the package itself
stays pure Dart and storage/connectivity-agnostic):

| Concern | What the host provides |
|---|---|
| Storage adapters | `QueueService` / `ActionService` over a local store (Hive, SQLite, Drift…), each record persisted as a plain JSON map |
| Watermark store | `StorageWatermarkStore` over your key/value store, or a custom `WatermarkStore` |
| Connectivity adapter | `SyncConnectivity` backed by platform connectivity + a real reachability check |
| DI wiring + `start()` | construct the engine, register processors/collections, then `await engine.start()` |
| Pull collections | one `SyncCollection<T>` per replicated dataset |
| Processors | one `IActionProcessor` per queued action type |
| Outbox writers | repositories that `submit(TaskDraft)` for work created offline |
| Sync UI | a view that projects `engine.events` / `engine.statusStream` |
| Resume / background triggers | a lifecycle observer and/or OS background task that calls `engine.sync()` |

---

## License

[MIT](LICENSE) © Nabil Aguida
