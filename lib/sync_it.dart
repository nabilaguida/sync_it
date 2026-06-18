/// Offline-first synchronization engine.
///
/// See README.md for the architecture and integration guide.
library;

// Engine
export 'src/clock.dart';
export 'src/engine/background_sync_manager.dart';
export 'src/engine/ref_resolver.dart' show RefResolver, RefResolutionException;
export 'src/engine/sync_engine.dart';

// Errors & policy
export 'src/errors/sync_exceptions.dart';
export 'src/policy/retry_policy.dart';

// Interfaces implemented by the host app
export 'src/interfaces/action_processor.dart';
export 'src/interfaces/action_service.dart';
export 'src/interfaces/background_processor.dart';
export 'src/interfaces/queue_service.dart';
export 'src/interfaces/sync_connectivity.dart';
export 'src/interfaces/sync_storage.dart';

// Models & events
export 'src/models/queue_action.dart';
export 'src/models/queue_action_status.dart';
export 'src/models/queue_task.dart';
export 'src/models/sync_event.dart';
export 'src/models/sync_report.dart';
export 'src/models/sync_status_event.dart';

// Outbox (write side)
export 'src/outbox/sync_outbox.dart';
export 'src/outbox/task_draft.dart';

// Pull replication
export 'src/pull/collection_syncer.dart' show PullResult;
export 'src/pull/sync_collection.dart';
export 'src/pull/watermark_store.dart';

// Default implementations (tests, examples, simple hosts)
export 'src/implementations/in_memory_action_service.dart';
export 'src/implementations/in_memory_queue_service.dart';
export 'src/implementations/in_memory_sync_storage.dart';
