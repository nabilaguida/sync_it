import 'package:logging/logging.dart';

import '../clock.dart';
import '../interfaces/action_processor.dart';
import '../interfaces/action_service.dart';
import '../interfaces/queue_service.dart';
import '../interfaces/sync_connectivity.dart';
import '../models/queue_action.dart';
import '../models/queue_task.dart';
import '../models/sync_event.dart';
import '../policy/retry_policy.dart';
import 'action_runner.dart';
import 'queue_janitor.dart';
import 'ref_resolver.dart';

/// Mutable counters accumulated over one drain run.
class DrainCounts {
  int syncedActions = 0;
  int retryingActions = 0;
  int failedActions = 0;
  int syncedTasks = 0;
  int failedTasks = 0;
}

/// Executes the offline queue against registered processors: resolves
/// dependencies (within and across tasks), applies the [RetryPolicy],
/// and cleans up completed records. Individual action execution is
/// delegated to [ActionRunner].
class OutboxDrainer {
  OutboxDrainer({
    required QueueService queueService,
    required ActionService actionService,
    required Map<String, IActionProcessor> processors,
    required SyncConnectivity connectivity,
    required RetryPolicy retryPolicy,
    required void Function(SyncEvent event) emit,
    Clock clock = systemClock,
    this.maxPasses = 10,
    this.emptyTaskGrace = const Duration(minutes: 10),
  })  : _queueService = queueService,
        _actionService = actionService,
        _connectivity = connectivity,
        _retryPolicy = retryPolicy,
        _emit = emit,
        _clock = clock,
        _runner = ActionRunner(
          actionService: actionService,
          processors: processors,
          shouldRetry: retryPolicy.shouldRetry,
          maxAttempts: retryPolicy.maxAttempts,
          emit: emit,
          clock: clock,
        ),
        _janitor = QueueJanitor(
          queueService: queueService,
          actionService: actionService,
        );

  static final _log = Logger('OutboxDrainer');

  final QueueService _queueService;
  final ActionService _actionService;
  final SyncConnectivity _connectivity;
  final RetryPolicy _retryPolicy;
  final void Function(SyncEvent event) _emit;
  final Clock _clock;
  final ActionRunner _runner;
  final QueueJanitor _janitor;

  /// Bound on full passes over the task list per drain. Each pass only
  /// re-runs when the previous one made progress, so this caps the
  /// longest dependency chain resolvable in one drain.
  final int maxPasses;

  /// How long a task may exist with zero actions before it is treated as
  /// a corrupt enqueue (crash mid-submit) and failed loudly.
  final Duration emptyTaskGrace;

  Future<DrainCounts> drain() async {
    final counts = DrainCounts();
    // Action results accumulated across the entire drain, backed by the
    // results persisted on done actions. Refs make lookups explicit, so
    // a shared cache is safe (v1 cleared it per task to protect a
    // scan-all-results hack).
    final results = <String, dynamic>{};
    final startedTasks = <String>{};

    var madeProgress = true;
    var pass = 0;
    while (madeProgress && pass < maxPasses) {
      madeProgress = false;
      pass++;

      final pendingTasks = await _queueService.getPendingTasks();
      for (final task in pendingTasks) {
        if (!await _connectivity.isOnline) {
          _log.info('Lost connectivity during drain; pausing');
          return counts;
        }
        final progressed =
            await _processTask(task, results, counts, startedTasks);
        madeProgress = madeProgress || progressed;
      }
    }
    if (pass >= maxPasses) {
      _log.warning('Drain stopped at maxPasses ($maxPasses)');
    }

    await _janitor.sweep();
    return counts;
  }

  Future<bool> _processTask(
    QueueTask task,
    Map<String, dynamic> results,
    DrainCounts counts,
    Set<String> startedTasks,
  ) async {
    final actions = await _actionService.getActionsForQueue(task.id);

    if (actions.isEmpty) {
      return _handleEmptyTask(task, counts);
    }

    for (final action in actions) {
      final result = action.result;
      if (action.status == QueueActionStatus.done && result != null) {
        results.putIfAbsent(action.id, () => result);
      }
    }

    var progressed = false;
    var ranSomething = true;
    while (ranSomething) {
      ranSomething = false;

      final current = await _actionService.getActionsForQueue(task.id);
      final runnable = current.where(_isPending).toList();
      if (runnable.isEmpty) break;

      for (final action in runnable) {
        if (!await _connectivity.isOnline) return progressed;

        if (!_retryPolicy.isEligible(
          retryCount: action.retryCount,
          lastAttemptAtMs: action.lastAttemptAt,
          now: _clock(),
        )) {
          continue; // Still backing off.
        }

        final ready = await _dependenciesReady(action, results, counts);
        if (!ready) continue;

        if (startedTasks.add(task.id)) {
          _emit(TaskSyncStarted(task));
        }
        final outcome = await _runner.run(action, results, counts);
        if (outcome == ActionRunOutcome.executed) {
          ranSomething = true;
          progressed = true;
        }
      }
    }

    await _settleTaskStatus(task, counts);
    return progressed;
  }

  bool _isPending(QueueAction a) =>
      a.status == QueueActionStatus.pending ||
      a.status == QueueActionStatus.retryPending;

  Future<bool> _handleEmptyTask(QueueTask task, DrainCounts counts) async {
    final age = _clock().millisecondsSinceEpoch - task.createdAt;
    if (age > emptyTaskGrace.inMilliseconds) {
      const error = 'Task has no actions (enqueue was interrupted); '
          'it cannot be synced';
      _log.severe('Task ${task.id} (${task.type}): $error');
      await _failTask(task, error, counts);
    }
    return false;
  }

  /// Returns true when every dependency (declared + `$ref`-implied) is
  /// done and its result is loaded into [results]. Marks the action
  /// permanently failed if a dependency record no longer exists.
  Future<bool> _dependenciesReady(
    QueueAction action,
    Map<String, dynamic> results,
    DrainCounts counts,
  ) async {
    final depIds = <String>{
      ...action.dependencies,
      ...RefResolver.referencedActionIds(action.payload),
    };

    for (final depId in depIds) {
      if (results.containsKey(depId)) continue;

      final all = await _actionService.getAllActions();
      QueueAction? dep;
      for (final candidate in all) {
        if (candidate.id == depId) {
          dep = candidate;
          break;
        }
      }

      if (dep == null) {
        await _runner.markFailed(
          action,
          'Dependency $depId no longer exists',
          isConflict: false,
          counts: counts,
        );
        return false;
      }
      if (dep.status != QueueActionStatus.done) return false; // Not yet.
      final depResult = dep.result;
      if (depResult != null) results[depId] = depResult;
    }
    return true;
  }

  Future<void> _settleTaskStatus(QueueTask task, DrainCounts counts) async {
    final actions = await _actionService.getActionsForQueue(task.id);
    if (actions.isEmpty) return;

    final allDone = actions.every((a) => a.status == QueueActionStatus.done);
    if (allDone) {
      final synced = task.copyWith(
        status: QueueTaskStatus.synced,
        lastError: null,
        updatedAt: _clock().millisecondsSinceEpoch,
      );
      await _queueService.updateTask(synced);
      _emit(TaskSynced(synced));
      counts.syncedTasks++;
      await _janitor.removeCompleted(synced, actions);
      return;
    }

    String? firstFailure;
    for (final action in actions) {
      if (action.status == QueueActionStatus.failedPermanent) {
        firstFailure =
            action.lastError ?? 'Action ${action.type} failed permanently';
        break;
      }
    }
    if (firstFailure != null) {
      if (task.status != QueueTaskStatus.syncFailed ||
          task.lastError != firstFailure) {
        await _failTask(task, firstFailure, counts);
      }
      return;
    }
    // Only transient failures: leave the task pendingSync for next time.
  }

  Future<void> _failTask(
    QueueTask task,
    String error,
    DrainCounts counts,
  ) async {
    final failed = task.copyWith(
      status: QueueTaskStatus.syncFailed,
      lastError: error,
      updatedAt: _clock().millisecondsSinceEpoch,
    );
    await _queueService.updateTask(failed);
    _emit(TaskSyncFailed(failed, error));
    counts.failedTasks++;
  }
}
