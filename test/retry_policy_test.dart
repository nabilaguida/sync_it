import 'package:sync_it/sync_it.dart';
import 'package:test/test.dart';

void main() {
  group('RetryPolicy', () {
    const policy = RetryPolicy(
      maxAttempts: 3,
      initialBackoff: Duration(seconds: 2),
      multiplier: 2.0,
      maxBackoff: Duration(seconds: 60),
    );

    test('shouldRetry allows up to maxAttempts', () {
      expect(policy.shouldRetry(0), isTrue);
      expect(policy.shouldRetry(2), isTrue);
      expect(policy.shouldRetry(3), isFalse);
    });

    test('backoff grows exponentially and is capped', () {
      expect(policy.backoffFor(0), Duration.zero);
      expect(policy.backoffFor(1), const Duration(seconds: 2));
      expect(policy.backoffFor(2), const Duration(seconds: 4));
      expect(policy.backoffFor(3), const Duration(seconds: 8));
      expect(policy.backoffFor(10), const Duration(seconds: 60));
    });

    test('isEligible respects backoff window', () {
      final failedAt = DateTime(2026, 6, 12, 12, 0, 0);
      final tooSoon = failedAt.add(const Duration(seconds: 1));
      final lateEnough = failedAt.add(const Duration(seconds: 2));

      expect(
        policy.isEligible(
          retryCount: 1,
          lastAttemptAtMs: failedAt.millisecondsSinceEpoch,
          now: tooSoon,
        ),
        isFalse,
      );
      expect(
        policy.isEligible(
          retryCount: 1,
          lastAttemptAtMs: failedAt.millisecondsSinceEpoch,
          now: lateEnough,
        ),
        isTrue,
      );
      expect(
        policy.isEligible(
          retryCount: 0,
          lastAttemptAtMs: 0,
          now: failedAt,
        ),
        isTrue,
      );
    });
  });

  group('RefResolver', () {
    test('builds and detects refs', () {
      final ref = RefResolver.ref('abc', 'id');
      expect(ref, r'$ref:abc:id');
      expect(RefResolver.isRef(ref), isTrue);
      expect(RefResolver.isRef('plain'), isFalse);
    });

    test('collects referenced action ids from nested payloads', () {
      final ids = RefResolver.referencedActionIds({
        'order': {'id': r'$ref:a1:id'},
        'lines': [
          {'customer': r'$ref:a2:customer.id'},
        ],
        'note': 'no ref here',
      });
      expect(ids, {'a1', 'a2'});
    });

    test('resolves dot paths and whole results', () {
      final results = {
        'a1': {
          'id': 42,
          'customer': {'id': 7},
        },
      };
      final resolved = RefResolver.resolve({
        'orderId': r'$ref:a1:id',
        'customerId': r'$ref:a1:customer.id',
        'whole': r'$ref:a1',
      }, results)! as Map<String, dynamic>;

      expect(resolved['orderId'], 42);
      expect(resolved['customerId'], 7);
      expect(resolved['whole'], results['a1']);
    });

    test('throws on missing result or path', () {
      expect(
        () => RefResolver.resolve(r'$ref:missing:id', {}),
        throwsA(isA<RefResolutionException>()),
      );
      expect(
        () => RefResolver.resolve(r'$ref:a1:nope', {
          'a1': {'id': 1},
        }),
        throwsA(isA<RefResolutionException>()),
      );
    });
  });
}
