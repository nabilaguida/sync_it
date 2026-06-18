import '../models/queue_task.dart';

/// Abstraction over storage for high-level sync tasks.
abstract class QueueService {
  /// Enqueue a new task.
  Future<void> enqueue(QueueTask task);

  /// Tasks that are pending sync or have previously failed,
  /// oldest first.
  Future<List<QueueTask>> getPendingTasks();

  /// Every stored task regardless of status.
  Future<List<QueueTask>> getAllTasks();

  /// Update an existing task.
  Future<void> updateTask(QueueTask task);

  /// Remove a task permanently.
  Future<void> removeTask(String taskId);

  /// Remove all tasks.
  Future<void> clearTasks();
}
