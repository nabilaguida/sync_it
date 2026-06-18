/// Interface for periodic background synchronization tasks.
abstract class IBackgroundProcessor {
  /// Unique name for the processor.
  String get name;

  /// Interval between executions.
  Duration get interval;

  /// Executes the synchronization logic.
  Future<void> execute();
}
