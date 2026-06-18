import 'package:equatable/equatable.dart';

/// Status of a queue action.
///
/// Persisted string values are stable — never change them, devices in the
/// field hold serialized records.
enum QueueActionStatus {
  pending,
  retryPending,
  done,
  failedPermanent;

  String toValue() {
    switch (this) {
      case QueueActionStatus.pending:
        return 'pending';
      case QueueActionStatus.retryPending:
        return 'retry_pending';
      case QueueActionStatus.done:
        return 'done';
      case QueueActionStatus.failedPermanent:
        return 'failed_permanent';
    }
  }

  static QueueActionStatus fromValue(String value) {
    switch (value) {
      case 'pending':
        return QueueActionStatus.pending;
      case 'retry_pending':
        return QueueActionStatus.retryPending;
      case 'done':
        return QueueActionStatus.done;
      case 'failed_permanent':
        return QueueActionStatus.failedPermanent;
      default:
        throw ArgumentError('Unknown QueueActionStatus value: $value');
    }
  }
}

/// An individual executable step within a [QueueTask].
///
/// [type] is a string key matching a registered `IActionProcessor`
/// (typically an enum name, e.g. 'CREATE_ORDER').
///
/// String values inside [payload] of the form `$ref:<actionId>:<path>`
/// are resolved by the engine to fields of that action's persisted
/// result before the processor runs, and implicitly add `<actionId>` to
/// [dependencies].
class QueueAction extends Equatable {
  QueueAction({
    required this.id,
    required this.queueId,
    required this.type,
    required this.payload,
    required this.status,
    required this.idempotencyKey,
    required this.createdAt,
    required this.lastAttemptAt,
    List<String>? dependencies,
    @Deprecated('Use dependencies instead') String? dependsOn,
    this.result,
    this.retryCount = 0,
    this.lastError,
  }) : dependencies = dependencies ??
            // ignore: deprecated_member_use_from_same_package
            (dependsOn == null ? const [] : [dependsOn]);

  final String id;

  /// FK to the owning [QueueTask].
  final String queueId;
  final String type;
  final Map<String, dynamic> payload;
  final QueueActionStatus status;

  /// Action IDs that must reach [QueueActionStatus.done] before this one
  /// runs. May reference actions in other tasks.
  final List<String> dependencies;

  /// Processor result, persisted so dependent actions (and `$ref`
  /// placeholders) can read it across passes and restarts.
  final Map<String, dynamic>? result;

  /// Failed attempts so far. Drives `RetryPolicy` backoff/escalation.
  final int retryCount;

  /// Unique key the processor MUST forward to the server so replays
  /// after an ambiguous failure (e.g. timeout) don't duplicate work.
  final String idempotencyKey;

  /// Message of the most recent failure, for diagnostics/UI. Cleared on
  /// success.
  final String? lastError;

  /// Epoch milliseconds.
  final int createdAt;
  final int lastAttemptAt;

  /// Legacy single-dependency view (first entry of [dependencies]).
  @Deprecated('Use dependencies instead')
  String? get dependsOn => dependencies.isEmpty ? null : dependencies.first;

  static const Object _unset = Object();

  QueueAction copyWith({
    String? id,
    String? queueId,
    String? type,
    Map<String, dynamic>? payload,
    QueueActionStatus? status,
    List<String>? dependencies,
    Map<String, dynamic>? result,
    int? retryCount,
    String? idempotencyKey,
    Object? lastError = _unset,
    int? createdAt,
    int? lastAttemptAt,
  }) {
    return QueueAction(
      id: id ?? this.id,
      queueId: queueId ?? this.queueId,
      type: type ?? this.type,
      payload: payload ?? this.payload,
      status: status ?? this.status,
      dependencies: dependencies ?? this.dependencies,
      result: result ?? this.result,
      retryCount: retryCount ?? this.retryCount,
      idempotencyKey: idempotencyKey ?? this.idempotencyKey,
      lastError:
          identical(lastError, _unset) ? this.lastError : lastError as String?,
      createdAt: createdAt ?? this.createdAt,
      lastAttemptAt: lastAttemptAt ?? this.lastAttemptAt,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'queueId': queueId,
      'type': type,
      'payload': payload,
      'status': status.toValue(),
      'dependencies': dependencies,
      // Written for rollback safety: a v1 reader only sees `dependsOn`.
      'dependsOn': dependencies.isEmpty ? null : dependencies.first,
      'result': result,
      'retryCount': retryCount,
      'idempotencyKey': idempotencyKey,
      'lastError': lastError,
      'createdAt': createdAt,
      'lastAttemptAt': lastAttemptAt,
    };
  }

  factory QueueAction.fromMap(Map<String, dynamic> map) {
    final rawDeps = map['dependencies'];
    final legacyDep = map['dependsOn'] as String?;
    return QueueAction(
      id: map['id'] as String,
      queueId: map['queueId'] as String,
      type: map['type'] as String,
      payload: Map<String, dynamic>.from(map['payload'] as Map),
      status: QueueActionStatus.fromValue(map['status'] as String),
      dependencies: rawDeps is List
          ? rawDeps.cast<String>()
          : (legacyDep == null ? const [] : [legacyDep]),
      result: map['result'] != null
          ? Map<String, dynamic>.from(map['result'] as Map)
          : null,
      retryCount: map['retryCount'] as int? ?? 0,
      idempotencyKey: map['idempotencyKey'] as String,
      lastError: map['lastError'] as String?,
      createdAt: map['createdAt'] as int,
      lastAttemptAt: map['lastAttemptAt'] as int,
    );
  }

  @override
  List<Object?> get props => [
        id,
        queueId,
        type,
        payload,
        status,
        dependencies,
        result,
        retryCount,
        idempotencyKey,
        lastError,
        createdAt,
        lastAttemptAt,
      ];
}
