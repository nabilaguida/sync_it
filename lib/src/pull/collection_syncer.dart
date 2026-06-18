import 'package:logging/logging.dart';

import '../clock.dart';
import '../models/sync_event.dart';
import 'sync_collection.dart';
import 'watermark_store.dart';

/// Outcome of pulling a single collection.
class PullResult {
  const PullResult({
    required this.collection,
    required this.itemsApplied,
    this.error,
  });

  final String collection;
  final int itemsApplied;

  /// Null on success. On failure, items applied before the error remain
  /// applied (applyPage is idempotent), but the watermark did not move.
  final String? error;

  bool get succeeded => error == null;
}

/// Runs the pull loop for one [SyncCollection]: watermark → paginate →
/// apply → advance watermark. Emits [CollectionPullStarted] /
/// [CollectionPullProgress] / [CollectionPullCompleted] /
/// [CollectionPullFailed] along the way.
class CollectionSyncer {
  CollectionSyncer({
    required WatermarkStore watermarks,
    required void Function(SyncEvent event) emit,
    Clock clock = systemClock,
  })  : _watermarks = watermarks,
        _emit = emit,
        _clock = clock;

  static final _log = Logger('CollectionSyncer');

  final WatermarkStore _watermarks;
  final void Function(SyncEvent event) _emit;
  final Clock _clock;

  Future<PullResult> pull(SyncCollection<dynamic> collection) async {
    final name = collection.name;
    _emit(CollectionPullStarted(name));

    var itemsApplied = 0;
    try {
      final since = await _watermarks.get(name);
      // Captured BEFORE fetching: rows updated while this pull runs fall
      // after the new watermark and are picked up next time.
      final pullStartedAt = _clock();

      var page = collection.firstPage;
      var pagesFetched = 0;
      var hasMore = true;
      var hitPageBound = false;

      while (hasMore) {
        if (pagesFetched >= collection.maxPages) {
          hitPageBound = true;
          _log.warning(
            'Pull of "$name" stopped at maxPages '
            '(${collection.maxPages}); watermark NOT advanced',
          );
          break;
        }

        final result = await collection.fetchPageErased(since, page);
        pagesFetched++;

        if (result.items.isNotEmpty) {
          await collection.applyPageErased(result.items);
          itemsApplied += result.items.length;
        }

        _emit(
          CollectionPullProgress(
            collection: name,
            page: pagesFetched,
            itemsApplied: itemsApplied,
            totalCount: result.totalCount,
          ),
        );

        hasMore = result.hasMore;
        page++;
      }

      if (!hitPageBound) {
        await _watermarks.set(name, pullStartedAt);
      }

      _emit(
        CollectionPullCompleted(collection: name, itemsApplied: itemsApplied),
      );
      _log.info('Pulled "$name": $itemsApplied item(s) applied');
      return PullResult(collection: name, itemsApplied: itemsApplied);
    } catch (e, st) {
      _log.severe('Pull of "$name" failed', e, st);
      _emit(CollectionPullFailed(name, e.toString()));
      return PullResult(
        collection: name,
        itemsApplied: itemsApplied,
        error: e.toString(),
      );
    }
  }
}
