import '../models/queue_action.dart';

/// Executes a single sync action (e.g. SaleOrder, Payment, StockMove).
///
/// The concrete implementations live in the host application.
abstract class IActionProcessor {
  /// Action type this processor supports.
  String get actionType;

  /// Executes the action payload.
  ///
  /// [previousResults] contains results of previously executed actions keyed by action ID.
  /// Implementations may ignore this map if they don't need dependency chaining.
  Future<Map<String, dynamic>> process(
    QueueAction action,
    Map<String, dynamic> previousResults,
  );
}




