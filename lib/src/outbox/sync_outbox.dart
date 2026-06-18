import 'dart:convert';

import 'package:logging/logging.dart';

import '../clock.dart';
import '../interfaces/action_service.dart';
import '../interfaces/queue_service.dart';
import '../models/queue_action.dart';
import '../models/queue_task.dart';
import 'task_draft.dart';

/// Result of [SyncOutbox.submit].
class SubmittedTask {
  const SubmittedTask({required this.taskId, required this.actionIds});
  final String taskId;
  final List<String> actionIds;
}

/// Write-side API of the offline queue.
///
/// All enqueueing goes through [submit], which orders writes so a crash
/// can never produce a task that looks synced without having run:
/// actions are persisted first, the task last — the task record is the
/// commit marker. Actions whose task never got written are swept by
/// [collectGarbage].
class SyncOutbox {
  SyncOutbox({
    required QueueService queueService,
    required ActionService actionService,
    Clock clock = systemClock,
  })  : _queueService = queueService,
        _actionService = actionService,
        _clock = clock;

  static final _log = Logger('SyncOutbox');

  final QueueService _queueService;
  final ActionService _actionService;
  final Clock _clock;

  /// Persists [draft] atomically-by-ordering (actions first, task last).
  ///
  /// Throws [ArgumentError] for a draft with no actions, and rethrows
  /// storage failures — callers MUST surface those to the user (a silent
  /// enqueue failure is a lost sale).
  Future<SubmittedTask> submit(TaskDraft draft) async {
    if (draft.actions.isEmpty) {
      throw ArgumentError('TaskDraft "${draft.type}" has no actions');
    }
    final nowMs = _clock().millisecondsSinceEpoch;

    final actions = draft.actions
        .map(
          (a) => QueueAction(
            id: a.id,
            queueId: draft.id,
            type: a.type,
            payload: _plainJson(a.payload),
            status: QueueActionStatus.pending,
            dependencies: a.dependencies,
            idempotencyKey: a.idempotencyKey,
            createdAt: nowMs,
            lastAttemptAt: 0,
          ),
        )
        .toList();

    for (final action in actions) {
      await _actionService.addAction(action);
    }
    // Written last: its presence commits the submission.
    await _queueService.enqueue(
      QueueTask(
        id: draft.id,
        type: draft.type,
        payload: _plainJson(draft.payload),
        status: QueueTaskStatus.pendingSync,
        createdAt: nowMs,
        updatedAt: nowMs,
      ),
    );

    _log.fine(
      'Submitted task ${draft.id} (${draft.type}) '
      'with ${actions.length} action(s)',
    );
    return SubmittedTask(
      taskId: draft.id,
      actionIds: actions.map((a) => a.id).toList(),
    );
  }

  /// First stored action matching [test], or null. Generic replacement
  /// for app-specific lookups (e.g. "find the pending customer-create
  /// action holding this temp ID").
  Future<QueueAction?> findActionWhere(
    bool Function(QueueAction action) test,
  ) async {
    final actions = await _actionService.getAllActions();
    for (final action in actions) {
      if (test(action)) return action;
    }
    return null;
  }

  /// First stored task matching [test], or null.
  Future<QueueTask?> findTaskWhere(bool Function(QueueTask task) test) async {
    final tasks = await _queueService.getAllTasks();
    for (final task in tasks) {
      if (test(task)) return task;
    }
    return null;
  }

  /// All actions belonging to [taskId], oldest first.
  Future<List<QueueAction>> actionsForTask(String taskId) =>
      _actionService.getActionsForQueue(taskId);

  /// Appends one action to an already-submitted task (e.g. a payment
  /// added to a queued offline order) and flips the task back to
  /// `pendingSync` so the engine picks it up.
  ///
  /// `$ref` placeholders in [payload] become dependencies automatically,
  /// in addition to [dependsOn]. Throws [StateError] if the task does
  /// not exist; rethrows storage failures (surface them to the user).
  Future<QueueAction> appendAction({
    required String taskId,
    required String type,
    Map<String, dynamic> payload = const {},
    List<String> dependsOn = const [],
    String? idempotencyKey,
  }) async {
    final task = await findTaskWhere((t) => t.id == taskId);
    if (task == null) {
      throw StateError('Cannot append action: task $taskId not found');
    }

    final draft = TaskDraft(type: task.type, id: taskId);
    final handle = draft.addAction(
      type: type,
      payload: payload,
      dependsOn: dependsOn,
      chainAfterPrevious: false,
      idempotencyKey: idempotencyKey,
    );
    final actionDraft = draft.actions.single;

    final nowMs = _clock().millisecondsSinceEpoch;
    final action = QueueAction(
      id: actionDraft.id,
      queueId: taskId,
      type: actionDraft.type,
      payload: _plainJson(actionDraft.payload),
      status: QueueActionStatus.pending,
      dependencies: actionDraft.dependencies,
      idempotencyKey: actionDraft.idempotencyKey,
      createdAt: nowMs,
      lastAttemptAt: 0,
    );
    await _actionService.addAction(action);
    await _queueService.updateTask(
      task.copyWith(status: QueueTaskStatus.pendingSync, updatedAt: nowMs),
    );

    _log.fine('Appended action ${handle.id} ($type) to task $taskId');
    return action;
  }

  /// Every stored task, oldest first.
  Future<List<QueueTask>> allTasks() => _queueService.getAllTasks();

  /// Tasks still waiting to sync (pending or failed), oldest first.
  Future<List<QueueTask>> pendingTasks() => _queueService.getPendingTasks();

  /// All stored actions, oldest first.
  Future<List<QueueAction>> allActions() => _actionService.getAllActions();

  /// Number of tasks still waiting to sync (pending or failed).
  Future<int> pendingTaskCount() async =>
      (await _queueService.getPendingTasks()).length;

  /// Moves every `failedPermanent` / `retryPending` action back to
  /// `pending` with a fresh retry budget, and failed tasks back to
  /// `pendingSync`. Returns the number of actions reset.
  Future<int> resetFailedActions() async {
    var reset = 0;
    final actions = await _actionService.getAllActions();
    for (final action in actions) {
      if (action.status == QueueActionStatus.failedPermanent ||
          action.status == QueueActionStatus.retryPending) {
        await _actionService.updateAction(
          action.copyWith(
            status: QueueActionStatus.pending,
            retryCount: 0,
          ),
        );
        reset++;
      }
    }
    final tasks = await _queueService.getAllTasks();
    for (final task in tasks) {
      if (task.status == QueueTaskStatus.syncFailed) {
        await _queueService.updateTask(
          task.copyWith(
            status: QueueTaskStatus.pendingSync,
            updatedAt: _clock().millisecondsSinceEpoch,
          ),
        );
      }
    }
    return reset;
  }

  /// Removes actions whose task record never landed (crash between the
  /// action writes and the task write of [submit]) once they are older
  /// than [olderThan]. Returns the number removed.
  Future<int> collectGarbage({
    Duration olderThan = const Duration(hours: 1),
  }) async {
    final taskIds =
        (await _queueService.getAllTasks()).map((t) => t.id).toSet();
    final threshold = _clock().subtract(olderThan).millisecondsSinceEpoch;

    var removed = 0;
    for (final action in await _actionService.getAllActions()) {
      if (!taskIds.contains(action.queueId) && action.createdAt < threshold) {
        _log.warning(
          'GC: removing orphan action ${action.id} (${action.type}) — '
          'task ${action.queueId} was never committed',
        );
        await _actionService.removeAction(action.id);
        removed++;
      }
    }
    return removed;
  }

  /// Empties the queue entirely (tasks and actions). Destructive; meant
  /// for explicit "clear cache" user flows.
  Future<void> clear() async {
    await _actionService.clearActions();
    await _queueService.clearTasks();
  }

  /// Deep-copies via JSON round-trip so stored payloads are guaranteed
  /// plain `Map<String, dynamic>` / `List` structures.
  static Map<String, dynamic> _plainJson(Map<String, dynamic> value) =>
      jsonDecode(jsonEncode(value)) as Map<String, dynamic>;
}
