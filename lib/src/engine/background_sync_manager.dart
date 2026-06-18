import 'dart:async';
import 'package:logging/logging.dart';
import '../interfaces/background_processor.dart';

/// Manages periodic background synchronization tasks.
class BackgroundSyncManager {
  static final _log = Logger('BackgroundSyncManager');

  final List<IBackgroundProcessor> _processors = [];
  final Map<String, Timer> _timers = {};
  final Map<String, bool> _runningTasks = {};

  /// Registered a new background processor.
  void registerProcessor(IBackgroundProcessor processor) {
    if (_processors.any((p) => p.name == processor.name)) {
      _log.warning('Processor with name ${processor.name} already registered.');
      return;
    }
    _processors.add(processor);
  }

  /// Starts all registered background processors.
  void start() {
    for (final processor in _processors) {
      if (_timers.containsKey(processor.name)) continue;

      _log.info('Starting background sync: ${processor.name} every ${processor.interval.inMinutes} minutes');
      
      // Run once immediately
      _runTask(processor);

      // Schedule periodic runs
      final timer = Timer.periodic(processor.interval, (timer) {
        _runTask(processor);
      });
      _timers[processor.name] = timer;
    }
  }

  /// Stops all background processors.
  void stop() {
    for (final timer in _timers.values) {
      timer.cancel();
    }
    _timers.clear();
    _log.info('All background sync tasks stopped.');
  }

  Future<void> _runTask(IBackgroundProcessor processor) async {
    if (_runningTasks[processor.name] == true) {
      _log.warning('Task ${processor.name} is already running. Skipping this interval.');
      return;
    }

    _runningTasks[processor.name] = true;
    try {
      _log.info('Background sync executing: ${processor.name}');
      await processor.execute();
      _log.info('Background sync completed: ${processor.name}');
    } catch (e, st) {
      _log.severe('Error in background sync: ${processor.name}', e, st);
    } finally {
      _runningTasks[processor.name] = false;
    }
  }

  /// Checks if the manager is currently running.
  bool get isRunning => _timers.isNotEmpty;
}
