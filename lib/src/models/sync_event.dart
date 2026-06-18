import 'queue_action.dart';
import 'queue_task.dart';
import 'sync_report.dart';

/// Base type for everything emitted on `SyncEngine.events`.
///
/// UIs subscribe to this single stream for live progress; nothing else
/// needs to be polled.
sealed class SyncEvent {
  const SyncEvent();
}

/// A sync run began. [pendingTasks] is the outbox depth at start.
class SyncStarted extends SyncEvent {
  const SyncStarted({required this.pendingTasks});
  final int pendingTasks;
}

/// A sync run finished (successfully or not). Inspect [report].
class SyncCompleted extends SyncEvent {
  const SyncCompleted(this.report);
  final SyncReport report;
}

/// The engine started executing actions of [task].
class TaskSyncStarted extends SyncEvent {
  const TaskSyncStarted(this.task);
  final QueueTask task;
}

/// All actions of [task] completed; the task is synced.
class TaskSynced extends SyncEvent {
  const TaskSynced(this.task);
  final QueueTask task;
}

/// [task] cannot complete (permanent action failure or corrupt record).
class TaskSyncFailed extends SyncEvent {
  const TaskSyncFailed(this.task, this.error);
  final QueueTask task;
  final String error;
}

/// One action executed successfully.
class ActionSynced extends SyncEvent {
  const ActionSynced(this.action);
  final QueueAction action;
}

/// One action failed. If [willRetry] the engine will re-attempt it after
/// backoff; otherwise it is permanently failed (or in [isConflict]) and
/// needs user intervention.
class ActionSyncFailed extends SyncEvent {
  const ActionSyncFailed(
    this.action,
    this.error, {
    required this.willRetry,
    this.isConflict = false,
  });
  final QueueAction action;
  final String error;
  final bool willRetry;
  final bool isConflict;
}

/// A pull of [collection] began.
class CollectionPullStarted extends SyncEvent {
  const CollectionPullStarted(this.collection);
  final String collection;
}

/// Page-by-page pull progress for [collection].
class CollectionPullProgress extends SyncEvent {
  const CollectionPullProgress({
    required this.collection,
    required this.page,
    required this.itemsApplied,
    this.totalCount,
  });
  final String collection;

  /// Pages fetched so far.
  final int page;

  /// Items handed to `applyPage` so far across all pages.
  final int itemsApplied;

  /// Server-reported total, when the API provides one.
  final int? totalCount;

  /// 0..1 when [totalCount] is known, otherwise null.
  double? get fraction {
    final total = totalCount;
    if (total == null || total <= 0) return null;
    final f = itemsApplied / total;
    return f > 1.0 ? 1.0 : f;
  }
}

/// Pull of [collection] finished; watermark advanced.
class CollectionPullCompleted extends SyncEvent {
  const CollectionPullCompleted({
    required this.collection,
    required this.itemsApplied,
  });
  final String collection;
  final int itemsApplied;
}

/// Pull of [collection] aborted. The watermark was NOT advanced, so the
/// next pull retries the same window.
class CollectionPullFailed extends SyncEvent {
  const CollectionPullFailed(this.collection, this.error);
  final String collection;
  final String error;
}
