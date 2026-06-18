import '../models/sync_event.dart';
import '../models/sync_status_event.dart';

/// Folds the typed [SyncEvent] stream into the coarse legacy
/// [SyncStatusEvent] snapshots kept for simple spinner-and-counter UIs.
SyncStatusEvent projectSyncStatus(SyncStatusEvent current, SyncEvent event) {
  switch (event) {
    case SyncStarted(:final pendingTasks):
      return SyncStatusEvent(
        isSyncing: true,
        totalPending: pendingTasks,
        syncedCount: 0,
        failedCount: 0,
      );
    case SyncCompleted(:final report):
      return SyncStatusEvent(
        isSyncing: false,
        totalPending: 0,
        syncedCount: report.syncedActions,
        failedCount: report.failedActions,
      );
    case TaskSyncStarted(:final task):
      return current.copyWith(currentTaskType: task.type);
    case ActionSynced(:final action):
      return current.copyWith(
        syncedCount: current.syncedCount + 1,
        currentActionType: action.type,
      );
    case ActionSyncFailed(:final action, :final willRetry):
      return current.copyWith(
        failedCount: willRetry ? current.failedCount : current.failedCount + 1,
        currentActionType: action.type,
      );
    default:
      return current;
  }
}
