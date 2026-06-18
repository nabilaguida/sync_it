import 'dart:async';

import 'package:sync_it/sync_it.dart';
import 'package:test/test.dart';

import 'helpers/fakes.dart';

void main() {
  group('SyncEngine push', () {
    test('executes a dependency chain in order and cleans up', () async {
      final h = EngineHarness();
      final order = <String>[];
      h.engine
        ..registerProcessor(TestProcessor('CREATE', (a, _) async {
          order.add('CREATE');
          return {'id': 42};
        }))
        ..registerProcessor(TestProcessor('OPEN', (a, _) async {
          order.add('OPEN');
          expect(a.payload['orderId'], 42); // $ref resolved
          return {'opened': true};
        }))
        ..registerProcessor(TestProcessor('VALIDATE', (a, _) async {
          order.add('VALIDATE');
          return {'ok': true};
        }));

      final draft = TaskDraft(type: 'SALE');
      final create = draft.addAction(type: 'CREATE');
      draft.addAction(type: 'OPEN', payload: {'orderId': create.ref('id')});
      draft.addAction(type: 'VALIDATE');
      await h.outbox.submit(draft);

      final report = await h.engine.sync(pull: false);

      expect(order, ['CREATE', 'OPEN', 'VALIDATE']);
      expect(report.syncedActions, 3);
      expect(report.syncedTasks, 1);
      // Fully synced task and actions are removed from storage.
      expect(await h.queueService.getAllTasks(), isEmpty);
      expect(await h.actionService.getAllActions(), isEmpty);
    });

    test('resolves cross-task dependencies via refs', () async {
      final h = EngineHarness();
      h.engine
        ..registerProcessor(TestProcessor('CREATE_CUSTOMER', (a, _) async {
          return {'id': 777};
        }))
        ..registerProcessor(TestProcessor('CREATE_ORDER', (a, _) async {
          expect(a.payload['customer'], {'id': 777});
          return {'id': 1};
        }));

      final customerDraft = TaskDraft(type: 'CUSTOMER');
      final createCustomer =
          customerDraft.addAction(type: 'CREATE_CUSTOMER');
      await h.outbox.submit(customerDraft);

      final orderDraft = TaskDraft(type: 'SALE');
      orderDraft.addAction(
        type: 'CREATE_ORDER',
        payload: {
          'customer': {'id': createCustomer.ref('id')},
        },
      );
      await h.outbox.submit(orderDraft);

      final report = await h.engine.sync(pull: false);
      expect(report.syncedActions, 2);
      expect(report.syncedTasks, 2);
      expect(await h.actionService.getAllActions(), isEmpty);
    });

    test('retryable failures back off, then escalate to permanent',
        () async {
      final h = EngineHarness(
        retryPolicy: const RetryPolicy(
          maxAttempts: 3,
          initialBackoff: Duration(seconds: 10),
        ),
      );
      var attempts = 0;
      h.engine.registerProcessor(TestProcessor('FLAKY', (a, _) async {
        attempts++;
        throw const RetryableSyncException('server 503');
      }));

      final draft = TaskDraft(type: 'T');
      draft.addAction(type: 'FLAKY');
      await h.outbox.submit(draft);

      // Attempt 1 fails; retry not yet eligible inside the same drain.
      var report = await h.engine.sync(pull: false);
      expect(attempts, 1);
      expect(report.retryingActions, 1);
      var action = (await h.actionService.getAllActions()).single;
      expect(action.status, QueueActionStatus.retryPending);
      expect(action.lastError, contains('server 503'));

      // Before backoff expires nothing runs.
      report = await h.engine.sync(pull: false);
      expect(attempts, 1);

      // Advance past backoff: attempt 2.
      h.clock.advance(const Duration(seconds: 11));
      await h.engine.sync(pull: false);
      expect(attempts, 2);

      // Attempt 3 exhausts the budget → failedPermanent + task syncFailed.
      h.clock.advance(const Duration(minutes: 5));
      report = await h.engine.sync(pull: false);
      expect(attempts, 3);
      expect(report.failedActions, 1);
      action = (await h.actionService.getAllActions()).single;
      expect(action.status, QueueActionStatus.failedPermanent);
      expect(action.lastError, contains('gave up after 3 attempts'));
      final task = (await h.queueService.getAllTasks()).single;
      expect(task.status, QueueTaskStatus.syncFailed);
      expect(task.lastError, isNotNull);

      // Permanently failed work is not re-attempted.
      h.clock.advance(const Duration(days: 1));
      await h.engine.sync(pull: false);
      expect(attempts, 3);
    });

    test('PermanentSyncException fails immediately without retries',
        () async {
      final h = EngineHarness();
      var attempts = 0;
      h.engine.registerProcessor(TestProcessor('BAD', (a, _) async {
        attempts++;
        throw const PermanentSyncException('422: invalid payload');
      }));
      final draft = TaskDraft(type: 'T');
      draft.addAction(type: 'BAD');
      await h.outbox.submit(draft);

      final report = await h.engine.sync(pull: false);
      expect(attempts, 1);
      expect(report.failedActions, 1);
      expect(report.retryingActions, 0);
      final action = (await h.actionService.getAllActions()).single;
      expect(action.status, QueueActionStatus.failedPermanent);
      expect(action.lastError, contains('422'));
    });

    test('ConflictSyncException is surfaced as a conflict event', () async {
      final h = EngineHarness();
      h.engine.registerProcessor(TestProcessor('EDIT', (a, _) async {
        throw const ConflictSyncException('version mismatch');
      }));
      final draft = TaskDraft(type: 'T');
      draft.addAction(type: 'EDIT');
      await h.outbox.submit(draft);

      await h.engine.sync(pull: false);
      final failure =
          h.events.whereType<ActionSyncFailed>().single;
      expect(failure.isConflict, isTrue);
      expect(failure.willRetry, isFalse);
    });

    test('missing processor fails the action loudly', () async {
      final h = EngineHarness();
      final draft = TaskDraft(type: 'T');
      draft.addAction(type: 'UNREGISTERED');
      await h.outbox.submit(draft);

      final report = await h.engine.sync(pull: false);
      expect(report.failedActions, 1);
      final action = (await h.actionService.getAllActions()).single;
      expect(action.lastError, contains('No processor registered'));
    });

    test('a task with zero actions past grace fails instead of '
        'vacuously syncing', () async {
      final h = EngineHarness();
      // v1 regression: crash between action and task writes left a task
      // with no actions, which `.every()` on an empty list marked synced.
      await h.queueService.enqueue(
        QueueTask(
          id: 'corrupt',
          type: 'SALE',
          payload: const {},
          status: QueueTaskStatus.pendingSync,
          createdAt: h.clock.current.millisecondsSinceEpoch,
          updatedAt: h.clock.current.millisecondsSinceEpoch,
        ),
      );

      // Within grace: untouched (a submit might still be completing).
      await h.engine.sync(pull: false);
      var task = (await h.queueService.getAllTasks()).single;
      expect(task.status, QueueTaskStatus.pendingSync);

      h.clock.advance(const Duration(minutes: 11));
      final report = await h.engine.sync(pull: false);
      task = (await h.queueService.getAllTasks()).single;
      expect(task.status, QueueTaskStatus.syncFailed);
      expect(task.lastError, contains('no actions'));
      expect(report.failedTasks, 1);
    });

    test('offline run is reported, not silently dropped', () async {
      final h = EngineHarness();
      h.connectivity.online = false;
      final report = await h.engine.sync();
      expect(report.skippedOffline, isTrue);
      await Future<void>.delayed(Duration.zero); // flush event stream
      expect(h.events.whereType<SyncCompleted>().single.report.skippedOffline,
          isTrue);
    });

    test('sync during sync coalesces into a follow-up run', () async {
      final h = EngineHarness();
      final gate = Completer<void>();
      var runs = 0;
      h.engine.registerProcessor(TestProcessor('SLOW', (a, _) async {
        runs++;
        if (runs == 1) await gate.future;
        return {'ok': true};
      }));

      final d1 = TaskDraft(type: 'T1');
      d1.addAction(type: 'SLOW');
      await h.outbox.submit(d1);

      final first = h.engine.sync(pull: false);
      await Future<void>.delayed(Duration.zero); // let the drain start
      expect(h.engine.isSyncing, isTrue);

      // Enqueued mid-run + a second sync request: must not be dropped.
      final d2 = TaskDraft(type: 'T2');
      d2.addAction(type: 'SLOW');
      await h.outbox.submit(d2);
      final second = h.engine.sync(pull: false);

      gate.complete();
      await first;
      await second;

      expect(runs, 2, reason: 'follow-up run must process the second task');
      expect(await h.queueService.getAllTasks(), isEmpty);
      expect(identical(await first, await second), isTrue,
          reason: 'coalesced callers share the same run future');
    });

    test('start() reacts to connectivity restoration', () async {
      final h = EngineHarness();
      var processed = 0;
      h.engine.registerProcessor(TestProcessor('A', (a, _) async {
        processed++;
        return {'ok': true};
      }));
      final draft = TaskDraft(type: 'T');
      draft.addAction(type: 'A');

      h.connectivity.online = false;
      await h.outbox.submit(draft);
      await h.engine.start();

      h.connectivity.goOnline();
      await Future<void>.delayed(const Duration(milliseconds: 10));

      expect(processed, 1);
      await h.engine.stop();
    });

    test('legacy statusStream carries real counters', () async {
      final h = EngineHarness();
      h.engine.registerProcessor(
          TestProcessor('A', (a, _) async => {'ok': true}));
      final draft = TaskDraft(type: 'T');
      draft.addAction(type: 'A');
      draft.addAction(type: 'A');
      await h.outbox.submit(draft);

      final statuses = <SyncStatusEvent>[];
      final sub = h.engine.statusStream.listen(statuses.add);
      await h.engine.sync(pull: false);
      await Future<void>.delayed(Duration.zero);
      await sub.cancel();

      expect(statuses.first.isSyncing, isTrue);
      expect(statuses.first.totalPending, 1);
      expect(statuses.any((s) => s.syncedCount == 2), isTrue);
      expect(statuses.last.isSyncing, isFalse);
    });
  });

  group('SyncEngine pull', () {
    SyncCollection<Map<String, dynamic>> collection({
      required List<List<Map<String, dynamic>>> pages,
      required List<Map<String, dynamic>> applied,
      List<DateTime?>? sinceLog,
      int? totalCount,
    }) {
      return SyncCollection<Map<String, dynamic>>(
        name: 'items',
        fetchPage: (since, page) async {
          sinceLog?.add(since);
          final index = page - 1;
          return PullPage(
            items: index < pages.length ? pages[index] : const [],
            hasMore: index < pages.length - 1,
            totalCount: totalCount,
          );
        },
        applyPage: (items) async => applied.addAll(items),
      );
    }

    test('paginates, applies every page, and advances the watermark',
        () async {
      final h = EngineHarness();
      final applied = <Map<String, dynamic>>[];
      final sinceLog = <DateTime?>[];
      h.engine.registerCollection(collection(
        pages: [
          [
            {'id': 1},
            {'id': 2},
          ],
          [
            {'id': 3},
          ],
        ],
        applied: applied,
        sinceLog: sinceLog,
        totalCount: 3,
      ));

      final pullStart = h.clock.current;
      final report = await h.engine.sync(push: false);

      expect(applied.length, 3);
      expect(report.pulled, {'items': 3});
      expect(sinceLog.first, isNull, reason: 'first sync pulls everything');
      expect(await h.watermarks.get('items'), pullStart);

      // Second sync passes the watermark as the delta floor.
      h.clock.advance(const Duration(hours: 1));
      await h.engine.sync(push: false);
      expect(sinceLog.last, pullStart);

      final progress =
          h.events.whereType<CollectionPullProgress>().toList();
      expect(progress.first.itemsApplied, 2);
      expect(progress.first.fraction, closeTo(2 / 3, 0.001));
    });

    test('a failed pull reports the error and keeps the watermark',
        () async {
      final h = EngineHarness();
      h.engine.registerCollection(
        SyncCollection<int>(
          name: 'broken',
          fetchPage: (_, __) async => throw Exception('api down'),
          applyPage: (_) async {},
        ),
      );

      final report = await h.engine.sync(push: false);
      expect(report.pullErrors.keys, contains('broken'));
      expect(await h.watermarks.get('broken'), isNull);
      expect(h.events.whereType<CollectionPullFailed>(), isNotEmpty);
    });

    test('maxPages bound stops a runaway API without advancing watermark',
        () async {
      final h = EngineHarness();
      h.engine.registerCollection(
        SyncCollection<int>(
          name: 'runaway',
          maxPages: 3,
          fetchPage: (_, page) async =>
              PullPage(items: [page], hasMore: true),
          applyPage: (_) async {},
        ),
      );

      final report = await h.engine.sync(push: false);
      expect(report.pulled['runaway'], 3);
      expect(await h.watermarks.get('runaway'), isNull,
          reason: 'incomplete pull must retry the same window next sync');
    });

    test('push runs before pull so local mutations reach the server first',
        () async {
      final h = EngineHarness();
      final sequence = <String>[];
      h.engine
        ..registerProcessor(TestProcessor('A', (a, _) async {
          sequence.add('push');
          return {'ok': true};
        }))
        ..registerCollection(
          SyncCollection<int>(
            name: 'c',
            fetchPage: (_, __) async {
              sequence.add('pull');
              return const PullPage(items: [], hasMore: false);
            },
            applyPage: (_) async {},
          ),
        );
      final draft = TaskDraft(type: 'T');
      draft.addAction(type: 'A');
      await h.outbox.submit(draft);

      await h.engine.sync();
      expect(sequence, ['push', 'pull']);
    });
  });
}
