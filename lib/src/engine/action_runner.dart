import 'dart:convert';

import 'package:logging/logging.dart';

import '../clock.dart';
import '../errors/sync_exceptions.dart';
import '../interfaces/action_processor.dart';
import '../interfaces/action_service.dart';
import '../models/queue_action.dart';
import '../models/sync_event.dart';
import 'outbox_drainer.dart' show DrainCounts;
import 'ref_resolver.dart';

/// Outcome of one action attempt.
enum ActionRunOutcome { executed, retrying, failedPermanently }

/// Executes a single ready action: resolves `$ref` placeholders, invokes
/// the registered processor, classifies failures per the retry policy,
/// and persists the resulting status + `lastError`.
class ActionRunner {
  ActionRunner({
    required ActionService actionService,
    required Map<String, IActionProcessor> processors,
    required bool Function(int attempts) shouldRetry,
    required int maxAttempts,
    required void Function(SyncEvent event) emit,
    Clock clock = systemClock,
  })  : _actionService = actionService,
        _processors = processors,
        _shouldRetry = shouldRetry,
        _maxAttempts = maxAttempts,
        _emit = emit,
        _clock = clock;

  static final _log = Logger('ActionRunner');

  final ActionService _actionService;
  final Map<String, IActionProcessor> _processors;
  final bool Function(int attempts) _shouldRetry;
  final int _maxAttempts;
  final void Function(SyncEvent event) _emit;
  final Clock _clock;

  /// Runs [action]; dependencies must already be satisfied and their
  /// results loaded into [results]. On success the result is added to
  /// [results] under the action's ID.
  Future<ActionRunOutcome> run(
    QueueAction action,
    Map<String, dynamic> results,
    DrainCounts counts,
  ) async {
    final processor = _processors[action.type];
    if (processor == null) {
      await markFailed(
        action,
        'No processor registered for action type "${action.type}"',
        isConflict: false,
        counts: counts,
      );
      return ActionRunOutcome.failedPermanently;
    }

    final QueueAction resolved;
    try {
      resolved = action.copyWith(
        payload: RefResolver.resolve(action.payload, results)!
            as Map<String, dynamic>,
      );
    } on RefResolutionException catch (e) {
      await markFailed(action, e.message, isConflict: false, counts: counts);
      return ActionRunOutcome.failedPermanently;
    }

    try {
      final result = await processor.process(resolved, results);
      // JSON round-trip guarantees the persisted result is plain data.
      final plain = jsonDecode(jsonEncode(result)) as Map<String, dynamic>;

      final done = action.copyWith(
        status: QueueActionStatus.done,
        result: plain,
        lastError: null,
        lastAttemptAt: _clock().millisecondsSinceEpoch,
      );
      await _actionService.updateAction(done);
      results[action.id] = plain;
      _emit(ActionSynced(done));
      counts.syncedActions++;
      return ActionRunOutcome.executed;
    } on PermanentSyncException catch (e) {
      await markFailed(action, e.message, isConflict: false, counts: counts);
      return ActionRunOutcome.failedPermanently;
    } on ConflictSyncException catch (e) {
      await markFailed(action, e.message, isConflict: true, counts: counts);
      return ActionRunOutcome.failedPermanently;
    } catch (e) {
      // Unknown errors (and RetryableSyncException) default to retryable.
      final message = e is RetryableSyncException ? e.message : e.toString();
      final attempts = action.retryCount + 1;
      if (_shouldRetry(attempts)) {
        final retrying = action.copyWith(
          status: QueueActionStatus.retryPending,
          retryCount: attempts,
          lastError: message,
          lastAttemptAt: _clock().millisecondsSinceEpoch,
        );
        await _actionService.updateAction(retrying);
        _emit(ActionSyncFailed(retrying, message, willRetry: true));
        counts.retryingActions++;
        _log.warning(
          'Action ${action.id} (${action.type}) failed '
          '(attempt $attempts/$_maxAttempts): $message',
        );
        return ActionRunOutcome.retrying;
      }
      await markFailed(
        action,
        '$message (gave up after $attempts attempts)',
        isConflict: false,
        counts: counts,
      );
      return ActionRunOutcome.failedPermanently;
    }
  }

  /// Persists a permanent failure with its reason and emits the event.
  Future<void> markFailed(
    QueueAction action,
    String error, {
    required bool isConflict,
    required DrainCounts counts,
  }) async {
    final failed = action.copyWith(
      status: QueueActionStatus.failedPermanent,
      retryCount: action.retryCount + 1,
      lastError: error,
      lastAttemptAt: _clock().millisecondsSinceEpoch,
    );
    await _actionService.updateAction(failed);
    _emit(
      ActionSyncFailed(failed, error, willRetry: false, isConflict: isConflict),
    );
    counts.failedActions++;
    _log.severe(
      'Action ${action.id} (${action.type}) failed permanently: $error',
    );
  }
}
