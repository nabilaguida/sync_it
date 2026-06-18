/// Typed failure channel between action processors and the [SyncEngine].
///
/// Processors classify their failures by throwing one of these types.
/// Any other thrown object is treated as [RetryableSyncException] —
/// the safe default for unknown errors (network blips, timeouts).
abstract class SyncException implements Exception {
  const SyncException(this.message, {this.cause});

  /// Human-readable description, persisted on the action as `lastError`.
  final String message;

  /// The underlying error, if any. Not persisted.
  final Object? cause;

  @override
  String toString() =>
      '$runtimeType: $message${cause == null ? '' : ' (cause: $cause)'}';
}

/// Transient failure — connection dropped, server 5xx, timeout.
///
/// The engine retries the action with exponential backoff until the
/// [RetryPolicy]'s max attempts is reached, then escalates to
/// `failedPermanent`.
class RetryableSyncException extends SyncException {
  const RetryableSyncException(super.message, {super.cause});
}

/// Non-recoverable failure — validation rejection (4xx), referenced
/// resource deleted, malformed payload.
///
/// The engine marks the action `failedPermanent` immediately; it will
/// never be retried automatically. The user can reset it explicitly via
/// `SyncOutbox.resetFailedActions()`.
class PermanentSyncException extends SyncException {
  const PermanentSyncException(super.message, {super.cause});
}

/// The remote state diverged from what the queued action expected
/// (edit conflict, version mismatch, duplicate detection).
///
/// Treated like [PermanentSyncException] for scheduling, but surfaced
/// as a distinct event so UIs can offer conflict resolution.
class ConflictSyncException extends SyncException {
  const ConflictSyncException(super.message, {super.cause});
}
