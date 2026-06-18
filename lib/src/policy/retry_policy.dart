import 'dart:math' as math;

/// Controls how many times a failed action is retried and how long the
/// engine waits between attempts.
///
/// `retryCount` below always means "attempts already made".
class RetryPolicy {
  const RetryPolicy({
    this.maxAttempts = 5,
    this.initialBackoff = const Duration(seconds: 2),
    this.multiplier = 2.0,
    this.maxBackoff = const Duration(minutes: 10),
  })  : assert(maxAttempts >= 1, 'maxAttempts must be >= 1'),
        assert(multiplier >= 1.0, 'multiplier must be >= 1.0');

  /// Retry immediately on every sync pass, forever.
  ///
  /// This reproduces the legacy v1 behavior. Not recommended: a
  /// deterministically failing action will block its task indefinitely.
  const RetryPolicy.legacyUnbounded()
      : maxAttempts = 1 << 30,
        initialBackoff = Duration.zero,
        multiplier = 1.0,
        maxBackoff = Duration.zero;

  /// Total attempts (first try + retries) before an action is escalated
  /// to `failedPermanent`.
  final int maxAttempts;

  /// Delay after the first failure. Doubles (by [multiplier]) per retry.
  final Duration initialBackoff;

  /// Backoff growth factor per retry.
  final double multiplier;

  /// Upper bound on the computed backoff.
  final Duration maxBackoff;

  /// Whether another attempt is allowed after [retryCount] failures.
  bool shouldRetry(int retryCount) => retryCount < maxAttempts;

  /// Delay required after the [retryCount]-th failure.
  Duration backoffFor(int retryCount) {
    if (retryCount <= 0 || initialBackoff == Duration.zero) {
      return Duration.zero;
    }
    final scaled = initialBackoff.inMilliseconds *
        math.pow(multiplier, retryCount - 1).toDouble();
    final capped = math.min(scaled, maxBackoff.inMilliseconds.toDouble());
    return Duration(milliseconds: capped.round());
  }

  /// Whether an action that last failed at [lastAttemptAtMs] (epoch ms,
  /// after [retryCount] failures) may be attempted again at [now].
  bool isEligible({
    required int retryCount,
    required int lastAttemptAtMs,
    required DateTime now,
  }) {
    if (retryCount <= 0) return true;
    final nextAttemptAt = DateTime.fromMillisecondsSinceEpoch(lastAttemptAtMs)
        .add(backoffFor(retryCount));
    return !now.isBefore(nextAttemptAt);
  }
}
