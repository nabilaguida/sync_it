/// One page of remote data returned by a [SyncCollection.fetchPage].
class PullPage<T> {
  const PullPage({
    required this.items,
    required this.hasMore,
    this.totalCount,
  });

  final List<T> items;

  /// Whether another page should be fetched after this one.
  final bool hasMore;

  /// Server-reported total matching items, if the API provides one.
  /// Used only for progress reporting.
  final int? totalCount;
}

/// Fetches one page. [since] is the collection's watermark (null on first
/// sync — fetch everything). [page] starts at [SyncCollection.firstPage].
typedef FetchPage<T> = Future<PullPage<T>> Function(DateTime? since, int page);

/// Persists one page of items into local storage. Must be idempotent
/// (upsert): pages may be re-applied when a pull is retried.
typedef ApplyPage<T> = Future<void> Function(List<T> items);

/// Declarative description of server data replicated into local storage.
///
/// The app supplies the two I/O callbacks; the engine owns everything
/// else: the watermark, the pagination loop, retry-on-next-sync
/// semantics, progress events, and the safety bound.
///
/// ```dart
/// SyncCollection<CustomerModel>(
///   name: 'customers',
///   fetchPage: (since, page) => remote.getCustomers(
///       updatedSince: since, page: page),
///   applyPage: (items) => local.cacheCustomers(items),
/// )
/// ```
class SyncCollection<T> {
  const SyncCollection({
    required this.name,
    required this.fetchPage,
    required this.applyPage,
    this.firstPage = 1,
    this.maxPages = 500,
  });

  /// Unique key. Also the watermark key and the name in progress events.
  final String name;

  final FetchPage<T> fetchPage;
  final ApplyPage<T> applyPage;

  /// First page index passed to [fetchPage] (1 for most APIs).
  final int firstPage;

  /// Hard bound on pages per pull, guarding against an API that never
  /// reports `hasMore: false`. Hitting it logs a warning and completes
  /// the pull WITHOUT advancing the watermark.
  final int maxPages;

  /// Type-erased bridges used by the engine. Necessary because the engine
  /// holds collections as `SyncCollection<dynamic>`, and reading the
  /// function-typed fields through that view fails Dart's covariance
  /// check; method signatures below don't vary with [T], so they don't.
  Future<PullPage<dynamic>> fetchPageErased(DateTime? since, int page) =>
      fetchPage(since, page);

  Future<void> applyPageErased(List<dynamic> items) =>
      applyPage(items.cast<T>());
}
