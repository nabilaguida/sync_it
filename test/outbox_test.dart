import 'package:sync_it/sync_it.dart';
import 'package:test/test.dart';

import 'helpers/fakes.dart';

void main() {
  late EngineHarness h;

  setUp(() => h = EngineHarness());

  group('TaskDraft', () {
    test('chains steps sequentially by default', () {
      final draft = TaskDraft(type: 'T');
      final a = draft.addAction(type: 'A');
      final b = draft.addAction(type: 'B');
      draft.addAction(type: 'C', dependsOn: [a]);

      expect(draft.actions[0].dependencies, isEmpty);
      expect(draft.actions[1].dependencies, [a.id]);
      expect(draft.actions[2].dependencies, [a.id]);
      expect(b.id, draft.actions[1].id);
    });

    test('payload refs become dependencies automatically', () {
      final draft = TaskDraft(type: 'T');
      final a = draft.addAction(type: 'A');
      draft.addAction(
        type: 'B',
        payload: {'orderId': a.ref('id')},
        chainAfterPrevious: false,
      );
      expect(draft.actions[1].dependencies, [a.id]);
    });

    test('idempotency key defaults to the action id', () {
      final draft = TaskDraft(type: 'T');
      final a = draft.addAction(type: 'A');
      expect(draft.actions.single.idempotencyKey, a.id);
    });
  });

  group('SyncOutbox.submit', () {
    test('persists actions first and the task as commit record', () async {
      final draft = TaskDraft(type: 'SALE', payload: {'tempId': -1});
      draft.addAction(type: 'CREATE', payload: {'x': 1});
      draft.addAction(type: 'OPEN');

      final submitted = await h.outbox.submit(draft);

      final tasks = await h.queueService.getAllTasks();
      final actions = await h.actionService.getAllActions();
      expect(tasks.single.id, submitted.taskId);
      expect(tasks.single.status, QueueTaskStatus.pendingSync);
      expect(actions.length, 2);
      expect(actions.every((a) => a.queueId == submitted.taskId), isTrue);
      expect(actions.every((a) => a.status == QueueActionStatus.pending),
          isTrue);
    });

    test('rejects drafts with no actions', () {
      expect(
        () => h.outbox.submit(TaskDraft(type: 'EMPTY')),
        throwsArgumentError,
      );
    });
  });

  group('SyncOutbox maintenance', () {
    test('collectGarbage removes only old orphan actions', () async {
      // Simulate a crash: actions written, task never committed.
      await h.actionService.addAction(
        QueueAction(
          id: 'orphan',
          queueId: 'ghost-task',
          type: 'A',
          payload: const {},
          status: QueueActionStatus.pending,
          idempotencyKey: 'orphan',
          createdAt: h.clock.current.millisecondsSinceEpoch,
          lastAttemptAt: 0,
        ),
      );

      // Too fresh — kept (could be a submit in progress).
      expect(await h.outbox.collectGarbage(), 0);

      h.clock.advance(const Duration(hours: 2));
      expect(await h.outbox.collectGarbage(), 1);
      expect(await h.actionService.getAllActions(), isEmpty);
    });

    test('resetFailedActions revives failed work', () async {
      final draft = TaskDraft(type: 'T');
      draft.addAction(type: 'A');
      final submitted = await h.outbox.submit(draft);

      final action =
          (await h.actionService.getAllActions()).single.copyWith(
        status: QueueActionStatus.failedPermanent,
        retryCount: 5,
        lastError: 'boom',
      );
      await h.actionService.updateAction(action);
      final task = (await h.queueService.getAllTasks()).single.copyWith(
            status: QueueTaskStatus.syncFailed,
          );
      await h.queueService.updateTask(task);

      expect(await h.outbox.resetFailedActions(), 1);

      final revived = (await h.actionService.getAllActions()).single;
      expect(revived.status, QueueActionStatus.pending);
      expect(revived.retryCount, 0);
      final revivedTask = (await h.queueService.getAllTasks()).single;
      expect(revivedTask.status, QueueTaskStatus.pendingSync);
      expect(revivedTask.id, submitted.taskId);
    });

    test('findActionWhere locates actions by payload', () async {
      final draft = TaskDraft(type: 'T');
      draft.addAction(type: 'CREATE_CUSTOMER', payload: {'tempId': -99});
      await h.outbox.submit(draft);

      final found = await h.outbox
          .findActionWhere((a) => a.payload['tempId'] == -99);
      expect(found, isNotNull);
      expect(found!.type, 'CREATE_CUSTOMER');
    });
  });

  group('model back-compat', () {
    test('v1 maps (dependsOn, no lastError) still deserialize', () {
      final action = QueueAction.fromMap({
        'id': 'a',
        'queueId': 'q',
        'type': 'T',
        'payload': {'x': 1},
        'status': 'retry_pending',
        'dependsOn': 'parent',
        'result': null,
        'retryCount': 2,
        'idempotencyKey': 'a',
        'createdAt': 1,
        'lastAttemptAt': 2,
      });
      expect(action.dependencies, ['parent']);
      expect(action.lastError, isNull);
      expect(action.status, QueueActionStatus.retryPending);

      final task = QueueTask.fromMap({
        'id': 't',
        'type': 'T',
        'payload': {},
        'status': 'pending_sync',
        'createdAt': 1,
        'updatedAt': 2,
      });
      expect(task.lastError, isNull);
    });

    test('toMap keeps legacy dependsOn field for rollback', () {
      final action = QueueAction(
        id: 'a',
        queueId: 'q',
        type: 'T',
        payload: const {},
        status: QueueActionStatus.pending,
        dependencies: const ['p1', 'p2'],
        idempotencyKey: 'a',
        createdAt: 1,
        lastAttemptAt: 0,
      );
      final map = action.toMap();
      expect(map['dependencies'], ['p1', 'p2']);
      expect(map['dependsOn'], 'p1');
    });
  });
}
