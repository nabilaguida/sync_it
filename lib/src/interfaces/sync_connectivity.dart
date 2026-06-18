/// Abstraction for network connectivity state used by SyncEngine.
abstract class SyncConnectivity {
  /// Returns true if the device is currently online.
  Future<bool> get isOnline;

  /// Stream emitting connectivity changes.
  Stream<bool> get onConnectivityChanged;
}




