import 'dart:async';

import 'package:logging/logging.dart';

import '../clock.dart';
import '../interfaces/action_processor.dart';
import '../interfaces/action_service.dart';
import '../interfaces/queue_service.dart';
import '../interfaces/sync_connectivity.dart';
import '../models/sync_event.dart';
import '../models/sync_report.dart';
import '../models/sync_status_event.dart';
import '../outbox/sync_outbox.dart';
import '../policy/retry_policy.dart';
import '../pull/collection_syncer.dart';
import '../pull/sync_collection.dart';
import '../pull/watermark_store.dart';
import 'outbox_drainer.dart';
import 'sync_status_projector.dart';

/// Orchestrates offline-first synchronization:
///
/// - **Push**: drains the offline queue ([outbox]) through registered
///   [IActionProcessor]s, in dependency order, with retry/backoff.
/// - **Pull**: replicates registered [SyncCollection]s into local
///   storage using per-collection watermarks.
/// - Emits everything observable on a single [events] stream.
///
/// Construction has no side effects; call [start] to begin reacting to
/// connectivity, [sync] to run on demand, and [stop]/[dispose] to tear
/// down.
class SyncEngine {
  SyncEngine({
    required this.connectivity,
    required QueueService queueService,
    required ActionService actionService,
    RetryPolicy retryPolicy = const RetryPolicy(),
    WatermarkStore? watermarks,
    Clock clock = systemClock,
    int maxPasses = 10,
    Duration emptyTaskGrace = const Duration(minutes: 10),
    Duration orphanActionAge = const Duration(hours: 1),
  })  : _queueService = queueService,
        _clock = clock,
        _watermarks = watermarks ?? InMemoryWatermarkStore(),
        _orphanActionAge = orphanActionAge {
    outbox = SyncOutbox(
      queueService: queueService,
      actionService: actionService,
      clock: clock,
    );
    _drainer = OutboxDrainer(
      queueService: queueService,
      actionService: actionService,
      processors: _processors,
      connectivity: connectivity,
      retryPolicy: retryPolicy,
      emit: _emit,
      clock: clock,
      maxPasses: maxPasses,
      emptyTaskGrace: emptyTaskGrace,
    );
    _collectionSyncer = CollectionSyncer(
      watermarks: _watermarks,
      emit: _emit,
      clock: clock,
    );
  }

  static final _log = Logger('SyncEngine');

  final SyncConnectivity connectivity;
  final QueueService _queueService;
  final Clock _clock;
  final WatermarkStore _watermarks;
  final Duration _orphanActionAge;

  /// Write-side API: submit drafts, reset failures, inspect the queue.
  late final SyncOutbox outbox;

  late final OutboxDrainer _drainer;
  late final CollectionSyncer _collectionSyncer;

  final Map<String, IActionProcessor> _processors = {};
  final Map<String, SyncCollection<dynamic>> _collections = {};

  StreamSubscription<bool>? _connectivitySubscription;

  final _eventController = StreamController<SyncEvent>.broadcast();
  final _statusController = StreamController<SyncStatusEvent>.broadcast();
  var _status = SyncStatusEvent.initial();

  Future<SyncReport>? _inFlight;
  bool _rerunPush = false;
  bool _rerunPull = false;

  /// Every observable engine occurrence (task/action/collection level).
  Stream<SyncEvent> get events => _eventController.stream;

  /// Coarse snapshot stream kept for simple UIs: emits on every event.
  Stream<SyncStatusEvent> get statusStream => _statusController.stream;

  bool get isSyncing => _inFlight != null;

  /// Registered collection names.
  Set<String> get collectionNames => Set.unmodifiable(_collections.keys);

  /// Register the executor for one action [IActionProcessor.actionType].
  void registerProcessor(IActionProcessor processor) {
    _processors[processor.actionType] = processor;
  }

  /// Register a pull-replicated collection.
  void registerCollection(SyncCollection<dynamic> collection) {
    _collections[collection.name] = collection;
  }

  /// Begin reacting to connectivity: a regained connection triggers a
  /// full [sync]. Idempotent.
  Future<void> start() async {
    _connectivitySubscription ??=
        connectivity.onConnectivityChanged.listen((isOnline) {
      if (isOnline) {
        _log.info('Connectivity restored — triggering sync');
        unawaited(sync());
      }
    });
  }

  /// Stop reacting to connectivity. In-flight syncs finish normally.
  Future<void> stop() async {
    await _connectivitySubscription?.cancel();
    _connectivitySubscription = null;
  }

  /// Pushes the outbox and/or pulls collections.
  ///
  /// Safe to call at any time: if a sync is already running the request
  /// is coalesced into an immediate follow-up run, and the returned
  /// future completes when everything (including the follow-up) is done.
  Future<SyncReport> sync({
    bool push = true,
    bool pull = true,
    Set<String>? collections,
  }) {
    final inFlight = _inFlight;
    if (inFlight != null) {
      _rerunPush = _rerunPush || push;
      _rerunPull = _rerunPull || pull;
      _log.fine('Sync already running — request coalesced into a rerun');
      return inFlight;
    }
    final run = _runLoop(push: push, pull: pull, collections: collections);
    _inFlight = run.whenComplete(() => _inFlight = null);
    return _inFlight!;
  }

  /// Pulls a single registered collection immediately.
  Future<PullResult> pullCollection(String name) {
    final collection = _collections[name];
    if (collection == null) {
      throw ArgumentError('No collection registered with name "$name"');
    }
    return _collectionSyncer.pull(collection);
  }

  Future<SyncReport> _runLoop({
    required bool push,
    required bool pull,
    Set<String>? collections,
  }) async {
    var report =
        await _runOnce(push: push, pull: pull, collections: collections);
    while (_rerunPush || _rerunPull) {
      final rerunPush = _rerunPush;
      final rerunPull = _rerunPull;
      _rerunPush = false;
      _rerunPull = false;
      _log.info('Running coalesced follow-up sync');
      report = await _runOnce(push: rerunPush, pull: rerunPull);
    }
    return report;
  }

  Future<SyncReport> _runOnce({
    required bool push,
    required bool pull,
    Set<String>? collections,
  }) async {
    final pendingAtStart = (await _queueService.getPendingTasks()).length;
    _status = SyncStatusEvent.initial();
    _emit(SyncStarted(pendingTasks: pendingAtStart));

    if (!await connectivity.isOnline) {
      _log.info('Sync skipped: offline');
      const report = SyncReport(skippedOffline: true);
      _emit(const SyncCompleted(report));
      return report;
    }

    try {
      var counts = DrainCounts();
      if (push) {
        await outbox.collectGarbage(olderThan: _orphanActionAge);
        counts = await _drainer.drain();
      }

      final pulled = <String, int>{};
      final pullErrors = <String, String>{};
      if (pull) {
        final names = collections ?? _collections.keys.toSet();
        for (final name in names) {
          final collection = _collections[name];
          if (collection == null) {
            pullErrors[name] = 'No collection registered with name "$name"';
            continue;
          }
          final result = await _collectionSyncer.pull(collection);
          final error = result.error;
          if (error == null) {
            pulled[name] = result.itemsApplied;
          } else {
            pullErrors[name] = error;
          }
        }
      }

      final report = SyncReport(
        syncedActions: counts.syncedActions,
        retryingActions: counts.retryingActions,
        failedActions: counts.failedActions,
        syncedTasks: counts.syncedTasks,
        failedTasks: counts.failedTasks,
        pulled: pulled,
        pullErrors: pullErrors,
      );
      _emit(SyncCompleted(report));
      _log.info('Sync finished: $report');
      return report;
    } catch (e, st) {
      // Engine-level invariant: a sync run never throws to its caller.
      // Storage-layer errors land here; they are reported, not hidden.
      _log.severe('Sync run aborted by unexpected error', e, st);
      final report = SyncReport(
        failedActions: 0,
        pullErrors: {'_engine': e.toString()},
      );
      _emit(SyncCompleted(report));
      return report;
    }
  }

  void _emit(SyncEvent event) {
    if (!_eventController.isClosed) {
      _eventController.add(event);
    }
    _status = projectSyncStatus(_status, event);
    if (!_statusController.isClosed) {
      _statusController.add(_status);
    }
  }

  /// Releases streams and the connectivity subscription.
  void dispose() {
    unawaited(stop());
    _eventController.close();
    _statusController.close();
  }

  /// Current time per the injected clock (exposed for hosts that want
  /// consistent timestamps, e.g. when recording a global last-sync time).
  DateTime now() => _clock();
}
