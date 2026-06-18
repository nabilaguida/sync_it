import '../interfaces/sync_storage.dart';

/// Simple in-memory SyncStorage implementation intended for tests
/// and examples. This is not persisted between app launches.
class InMemorySyncStorage<T> implements SyncStorage<T> {
  final Map<String, T> _values = {};

  @override
  Future<void> put(String key, T value) async {
    _values[key] = value;
  }

  @override
  Future<T?> get(String key) async => _values[key];

  @override
  Future<void> delete(String key) async {
    _values.remove(key);
  }

  @override
  Future<List<T>> getAll() async => _values.values.toList();
}
