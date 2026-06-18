import 'dart:async';

import 'package:sync_it/sync_it.dart';

/// Mutable, manually-advanced clock.
class FakeClock {
  FakeClock([DateTime? start])
      : current = start ?? DateTime(2026, 6, 12, 12, 0, 0);

  DateTime current;

  DateTime call() => current;

  void advance(Duration d) => current = current.add(d);
}

/// Connectivity whose state tests flip directly.
class FakeConnectivity implements SyncConnectivity {
  FakeConnectivity({this.online = true});

  bool online;
  final controller = StreamController<bool>.broadcast();

  @override
  Future<bool> get isOnline async => online;

  @override
  Stream<bool> get onConnectivityChanged => controller.stream;

  void goOnline() {
    online = true;
    controller.add(true);
  }

  void goOffline() {
    online = false;
    controller.add(false);
  }
}

/// Processor delegating to a closure; records every call.
class TestProcessor implements IActionProcessor {
  TestProcessor(
    this.actionType,
    Future<Map<String, dynamic>> Function(
      QueueAction action,
      Map<String, dynamic> previousResults,
    ) handler,
  ) : _handler = handler;

  @override
  final String actionType;

  final Future<Map<String, dynamic>> Function(
    QueueAction action,
    Map<String, dynamic> previousResults,
  ) _handler;

  final List<QueueAction> calls = [];

  @override
  Future<Map<String, dynamic>> process(
    QueueAction action,
    Map<String, dynamic> previousResults,
  ) {
    calls.add(action);
    return _handler(action, previousResults);
  }
}

/// Bundles a fully wired engine over in-memory services.
class EngineHarness {
  EngineHarness({
    RetryPolicy retryPolicy = const RetryPolicy(),
    Duration emptyTaskGrace = const Duration(minutes: 10),
  })  : clock = FakeClock(),
        connectivity = FakeConnectivity(),
        queueService = InMemoryQueueService(),
        actionService = InMemoryActionService(),
        watermarks = InMemoryWatermarkStore() {
    engine = SyncEngine(
      connectivity: connectivity,
      queueService: queueService,
      actionService: actionService,
      retryPolicy: retryPolicy,
      watermarks: watermarks,
      clock: clock.call,
      emptyTaskGrace: emptyTaskGrace,
    );
    events = [];
    engine.events.listen(events.add);
  }

  final FakeClock clock;
  final FakeConnectivity connectivity;
  final InMemoryQueueService queueService;
  final InMemoryActionService actionService;
  final InMemoryWatermarkStore watermarks;
  late final SyncEngine engine;
  late final List<SyncEvent> events;

  SyncOutbox get outbox => engine.outbox;
}
