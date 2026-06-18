import 'package:equatable/equatable.dart';

/// Status of a queue task.
///
/// Persisted string values are stable — never change them.
enum QueueTaskStatus {
  pendingSync,
  synced,
  syncFailed;

  String toValue() {
    switch (this) {
      case QueueTaskStatus.pendingSync:
        return 'pending_sync';
      case QueueTaskStatus.synced:
        return 'synced';
      case QueueTaskStatus.syncFailed:
        return 'sync_failed';
    }
  }

  static QueueTaskStatus fromValue(String value) {
    switch (value) {
      case 'pending_sync':
        return QueueTaskStatus.pendingSync;
      case 'synced':
        return QueueTaskStatus.synced;
      case 'sync_failed':
        return QueueTaskStatus.syncFailed;
      default:
        throw ArgumentError('Unknown QueueTaskStatus value: $value');
    }
  }
}

/// A high-level unit of offline work (e.g. one sale-order checkout),
/// composed of one or more [QueueAction] steps.
///
/// [type] is a string representation of a feature-specific enum, e.g.
/// 'SALE_ORDER'.
class QueueTask extends Equatable {
  const QueueTask({
    required this.id,
    required this.type,
    required this.payload,
    required this.status,
    required this.createdAt,
    required this.updatedAt,
    this.lastError,
  });

  final String id;
  final String type;
  final Map<String, dynamic> payload;
  final QueueTaskStatus status;

  /// Most recent failure affecting this task (permanent action failure,
  /// corrupt enqueue). Cleared when the task syncs.
  final String? lastError;

  /// Epoch milliseconds.
  final int createdAt;
  final int updatedAt;

  static const Object _unset = Object();

  QueueTask copyWith({
    String? id,
    String? type,
    Map<String, dynamic>? payload,
    QueueTaskStatus? status,
    Object? lastError = _unset,
    int? createdAt,
    int? updatedAt,
  }) {
    return QueueTask(
      id: id ?? this.id,
      type: type ?? this.type,
      payload: payload ?? this.payload,
      status: status ?? this.status,
      lastError:
          identical(lastError, _unset) ? this.lastError : lastError as String?,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'type': type,
      'payload': payload,
      'status': status.toValue(),
      'lastError': lastError,
      'createdAt': createdAt,
      'updatedAt': updatedAt,
    };
  }

  factory QueueTask.fromMap(Map<String, dynamic> map) {
    return QueueTask(
      id: map['id'] as String,
      type: map['type'] as String,
      payload: Map<String, dynamic>.from(map['payload'] as Map),
      status: QueueTaskStatus.fromValue(map['status'] as String),
      lastError: map['lastError'] as String?,
      createdAt: map['createdAt'] as int,
      updatedAt: map['updatedAt'] as int,
    );
  }

  @override
  List<Object?> get props =>
      [id, type, payload, status, lastError, createdAt, updatedAt];
}
