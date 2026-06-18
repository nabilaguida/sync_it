import 'package:uuid/uuid.dart';

import '../engine/ref_resolver.dart';

/// Handle to an action added to a [TaskDraft]. Use [ref] to point another
/// action's payload at this action's future server result.
class ActionHandle {
  const ActionHandle(this.id);

  /// The pre-generated action ID (valid before submission).
  final String id;

  /// A `$ref` placeholder resolving to this action's result.
  ///
  /// `handle.ref('id')` → the `id` field of the result map;
  /// `handle.ref()` → the whole result map.
  String ref([String path = '']) => RefResolver.ref(id, path);
}

/// One step inside a [TaskDraft]. Built via [TaskDraft.addAction].
class ActionDraft {
  ActionDraft({
    required this.id,
    required this.type,
    required this.payload,
    required this.dependencies,
    required this.idempotencyKey,
  });

  final String id;
  final String type;
  final Map<String, dynamic> payload;
  final List<String> dependencies;
  final String idempotencyKey;
}

/// Fluent builder for an offline task and its dependency-ordered actions.
///
/// IDs and `dependsOn` wiring are generated for you:
///
/// ```dart
/// final draft = TaskDraft(type: 'SALE_ORDER.createAndCheckout',
///     payload: {'tempId': tempId});
/// final create = draft.addAction(type: 'CREATE_ORDER', payload: body);
/// final open = draft.addAction(
///   type: 'OPEN_ORDER',
///   payload: {'orderId': create.ref('id')},
/// );
/// draft.addAction(type: 'VALIDATE_ALLOCATIONS',
///     payload: {'orderId': create.ref('id')}, dependsOn: [open]);
/// await engine.outbox.submit(draft);
/// ```
class TaskDraft {
  TaskDraft({
    required this.type,
    Map<String, dynamic>? payload,
    String? id,
  })  : id = id ?? const Uuid().v4(),
        payload = payload ?? <String, dynamic>{};

  final String id;
  final String type;
  final Map<String, dynamic> payload;

  final List<ActionDraft> actions = [];

  /// Adds a step. Execution order is governed by [dependsOn] (handles
  /// from this draft, or raw action IDs from other tasks) plus any
  /// `$ref` placeholders inside [payload] — both become persisted
  /// dependencies.
  ///
  /// If [dependsOn] is empty, [chainAfterPrevious] (default true) makes
  /// the step depend on the previously added one, so simple drafts read
  /// top-to-bottom as a sequence.
  ActionHandle addAction({
    required String type,
    Map<String, dynamic> payload = const {},
    List<Object> dependsOn = const [],
    bool chainAfterPrevious = true,
    String? idempotencyKey,
  }) {
    final actionId = const Uuid().v4();

    final deps = <String>{};
    for (final dep in dependsOn) {
      if (dep is ActionHandle) {
        deps.add(dep.id);
      } else if (dep is String) {
        deps.add(dep);
      } else {
        throw ArgumentError(
          'dependsOn entries must be ActionHandle or String, '
          'got ${dep.runtimeType}',
        );
      }
    }
    if (deps.isEmpty && chainAfterPrevious && actions.isNotEmpty) {
      deps.add(actions.last.id);
    }
    deps.addAll(RefResolver.referencedActionIds(payload));

    actions.add(
      ActionDraft(
        id: actionId,
        type: type,
        payload: payload,
        dependencies: deps.toList(),
        idempotencyKey: idempotencyKey ?? actionId,
      ),
    );
    return ActionHandle(actionId);
  }
}
