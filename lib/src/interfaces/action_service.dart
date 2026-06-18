import '../models/queue_action.dart';

/// Abstraction over storage for individual actions belonging to a QueueTask.
abstract class ActionService {
  Future<void> addAction(QueueAction action);
  Future<void> removeAction(String id);
  Future<void> updateAction(QueueAction action);
  Future<List<QueueAction>> getActionsForQueue(String queueId);
  Future<List<QueueAction>> getAllActions();
  Future<void> clearActions();
}




