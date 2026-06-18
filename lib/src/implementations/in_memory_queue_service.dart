import '../interfaces/queue_service.dart';
import '../models/queue_task.dart';

/// Simple in-memory QueueService implementation intended for tests
/// and examples. This is not persisted between app launches.
class InMemoryQueueService implements QueueService {
  final Map<String, QueueTask> _tasks = {};

  @override
  Future<void> enqueue(QueueTask task) async {
    _tasks[task.id] = task;
  }

  @override
  Future<List<QueueTask>> getPendingTasks() async {
    return _tasks.values
        .where(
          (t) =>
              t.status == QueueTaskStatus.pendingSync ||
              t.status == QueueTaskStatus.syncFailed,
        )
        .toList()
      ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
  }

  @override
  Future<List<QueueTask>> getAllTasks() async {
    return _tasks.values.toList()
      ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
  }

  @override
  Future<void> updateTask(QueueTask task) async {
    _tasks[task.id] = task;
  }

  @override
  Future<void> removeTask(String taskId) async {
    _tasks.remove(taskId);
  }

  @override
  Future<void> clearTasks() async {
    _tasks.clear();
  }
}
