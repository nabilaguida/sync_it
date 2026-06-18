/// Summary of one `SyncEngine.sync()` run.
class SyncReport {
  const SyncReport({
    this.skippedOffline = false,
    this.syncedActions = 0,
    this.retryingActions = 0,
    this.failedActions = 0,
    this.syncedTasks = 0,
    this.failedTasks = 0,
    this.pulled = const {},
    this.pullErrors = const {},
  });

  /// True when the run aborted immediately because the device is offline.
  final bool skippedOffline;

  /// Actions executed successfully in this run.
  final int syncedActions;

  /// Actions that failed but will be retried after backoff.
  final int retryingActions;

  /// Actions escalated to `failedPermanent` in this run.
  final int failedActions;

  /// Tasks fully synced (and cleaned up) in this run.
  final int syncedTasks;

  /// Tasks marked `syncFailed` in this run.
  final int failedTasks;

  /// Items applied per pulled collection (collection name → count).
  final Map<String, int> pulled;

  /// Collections whose pull failed (collection name → error message).
  final Map<String, String> pullErrors;

  bool get hasFailures => failedActions > 0 || pullErrors.isNotEmpty;

  @override
  String toString() =>
      'SyncReport(skippedOffline: $skippedOffline, syncedActions: '
      '$syncedActions, retryingActions: $retryingActions, failedActions: '
      '$failedActions, syncedTasks: $syncedTasks, failedTasks: $failedTasks, '
      'pulled: $pulled, pullErrors: $pullErrors)';
}
