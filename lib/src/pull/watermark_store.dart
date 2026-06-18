import '../interfaces/sync_storage.dart';

/// Persists the per-collection "last successful pull" timestamp.
///
/// The engine reads it before a pull (to build a delta filter) and
/// advances it only after the pull fully succeeds, so a failed pull
/// retries the same window.
abstract class WatermarkStore {
  Future<DateTime?> get(String collection);
  Future<void> set(String collection, DateTime value);
  Future<void> clear(String collection);
}

/// Default [WatermarkStore] over any `SyncStorage<String>` (Hive,
/// SharedPreferences, SQLite — whatever the host app provides).
/// Values are stored as ISO-8601 strings.
class StorageWatermarkStore implements WatermarkStore {
  StorageWatermarkStore(this._storage, {this.keyPrefix = 'sync_watermark_'});

  final SyncStorage<String> _storage;
  final String keyPrefix;

  @override
  Future<DateTime?> get(String collection) async {
    final raw = await _storage.get('$keyPrefix$collection');
    if (raw == null) return null;
    return DateTime.tryParse(raw);
  }

  @override
  Future<void> set(String collection, DateTime value) =>
      _storage.put('$keyPrefix$collection', value.toIso8601String());

  @override
  Future<void> clear(String collection) =>
      _storage.delete('$keyPrefix$collection');
}

/// Non-persistent store for tests and examples.
class InMemoryWatermarkStore implements WatermarkStore {
  final Map<String, DateTime> _values = {};

  @override
  Future<DateTime?> get(String collection) async => _values[collection];

  @override
  Future<void> set(String collection, DateTime value) async =>
      _values[collection] = value;

  @override
  Future<void> clear(String collection) async => _values.remove(collection);
}
