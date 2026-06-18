/// Generic persistence abstraction for sync queues and actions.
///
/// Apps can implement this using Hive, SQLite, Isar, etc.
abstract class SyncStorage<T> {
  Future<void> put(String key, T value);
  Future<T?> get(String key);
  Future<void> delete(String key);
  Future<List<T>> getAll();
}




