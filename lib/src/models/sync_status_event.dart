/// Coarse snapshot of sync progress, kept for simple UIs.
///
/// Prefer the typed `SyncEngine.events` stream for anything beyond a
/// spinner + counters.
class SyncStatusEvent {
  const SyncStatusEvent({
    required this.isSyncing,
    required this.totalPending,
    required this.syncedCount,
    required this.failedCount,
    this.currentTaskType,
    this.currentActionType,
  });

  final bool isSyncing;

  /// Outbox depth when the current run started.
  final int totalPending;

  /// Actions synced so far in the current run.
  final int syncedCount;

  /// Actions permanently failed so far in the current run.
  final int failedCount;

  /// Type of the task most recently started.
  final String? currentTaskType;

  /// Type of the action most recently executed.
  final String? currentActionType;

  factory SyncStatusEvent.initial() {
    return const SyncStatusEvent(
      isSyncing: false,
      totalPending: 0,
      syncedCount: 0,
      failedCount: 0,
    );
  }

  SyncStatusEvent copyWith({
    bool? isSyncing,
    int? totalPending,
    int? syncedCount,
    int? failedCount,
    String? currentTaskType,
    String? currentActionType,
  }) {
    return SyncStatusEvent(
      isSyncing: isSyncing ?? this.isSyncing,
      totalPending: totalPending ?? this.totalPending,
      syncedCount: syncedCount ?? this.syncedCount,
      failedCount: failedCount ?? this.failedCount,
      currentTaskType: currentTaskType ?? this.currentTaskType,
      currentActionType: currentActionType ?? this.currentActionType,
    );
  }
}
