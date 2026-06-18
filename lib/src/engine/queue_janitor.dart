import 'package:logging/logging.dart';

import '../interfaces/action_service.dart';
import '../interfaces/queue_service.dart';
import '../models/queue_action.dart';
import '../models/queue_task.dart';
import 'ref_resolver.dart';

/// Removes fully-synced tasks and actions from storage, keeping `done`
/// actions alive for as long as pending actions (in any task) still
/// depend on them via declared dependencies or `$ref` placeholders.
class QueueJanitor {
  QueueJanitor({
    required QueueService queueService,
    required ActionService actionService,
  })  : _queueService = queueService,
        _actionService = actionService;

  static final _log = Logger('QueueJanitor');

  final QueueService _queueService;
  final ActionService _actionService;

  /// Removes a synced [task]'s actions unless another pending action
  /// still depends on them; the task record follows once its last
  /// action goes.
  Future<void> removeCompleted(
    QueueTask task,
    List<QueueAction> actions,
  ) async {
    final dependedOn = await liveDependencyIds();
    var allRemoved = true;
    for (final action in actions) {
      if (dependedOn.contains(action.id)) {
        allRemoved = false;
        continue;
      }
      await _actionService.removeAction(action.id);
    }
    if (allRemoved) {
      await _queueService.removeTask(task.id);
    }
  }

  /// Post-drain sweep: delete done actions (and their emptied, synced
  /// tasks) that earlier passes kept alive as cross-task dependencies.
  Future<void> sweep() async {
    final dependedOn = await liveDependencyIds();
    final all = await _actionService.getAllActions();

    for (final action in all) {
      if (action.status != QueueActionStatus.done) continue;
      if (dependedOn.contains(action.id)) continue;

      final siblings = await _actionService.getActionsForQueue(action.queueId);
      final taskComplete = siblings.isNotEmpty &&
          siblings.every((a) => a.status == QueueActionStatus.done);
      if (!taskComplete) continue;

      await _actionService.removeAction(action.id);
      final remaining =
          await _actionService.getActionsForQueue(action.queueId);
      if (remaining.isEmpty) {
        _log.info('Cleanup: removing completed task ${action.queueId}');
        await _queueService.removeTask(action.queueId);
      }
    }
  }

  /// IDs that pending/retrying actions still reference.
  Future<Set<String>> liveDependencyIds() async {
    final all = await _actionService.getAllActions();
    final ids = <String>{};
    for (final action in all) {
      final pending = action.status == QueueActionStatus.pending ||
          action.status == QueueActionStatus.retryPending;
      if (!pending) continue;
      ids.addAll(action.dependencies);
      ids.addAll(RefResolver.referencedActionIds(action.payload));
    }
    return ids;
  }
}
