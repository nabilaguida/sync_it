import '../interfaces/action_service.dart';
import '../models/queue_action.dart';

/// Simple in-memory ActionService implementation intended for tests
/// and examples. This is not persisted between app launches.
class InMemoryActionService implements ActionService {
  final Map<String, QueueAction> _actions = {};

  @override
  Future<void> addAction(QueueAction action) async {
    _actions[action.id] = action;
  }

  @override
  Future<void> removeAction(String id) async {
    _actions.remove(id);
  }

  @override
  Future<void> updateAction(QueueAction action) async {
    _actions[action.id] = action;
  }

  @override
  Future<List<QueueAction>> getActionsForQueue(String queueId) async {
    return _actions.values.where((a) => a.queueId == queueId).toList()
      ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
  }

  @override
  Future<List<QueueAction>> getAllActions() async {
    return _actions.values.toList()
      ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
  }

  @override
  Future<void> clearActions() async {
    _actions.clear();
  }
}
