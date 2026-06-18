/// Resolves `$ref:<actionId>:<path>` placeholders inside action payloads.
///
/// A payload string value of the form `$ref:abc-123:id` is replaced, just
/// before the processor runs, with `result['id']` of action `abc-123`.
/// Nested paths use dots (`$ref:abc-123:customer.id`); omitting the path
/// (`$ref:abc-123`) substitutes the whole result map.
///
/// Every referenced action ID is implicitly a dependency: the engine will
/// not run an action until all its `$ref` targets are done.
class RefResolver {
  const RefResolver._();

  static const String _prefix = r'$ref:';

  /// Whether [value] is a ref placeholder.
  static bool isRef(Object? value) =>
      value is String && value.startsWith(_prefix);

  /// Builds a placeholder string for [actionId] (optionally a [path]
  /// into its result map).
  static String ref(String actionId, [String path = '']) =>
      path.isEmpty ? '$_prefix$actionId' : '$_prefix$actionId:$path';

  /// All action IDs referenced anywhere inside [node].
  static Set<String> referencedActionIds(Object? node) {
    final ids = <String>{};
    _walk(node, ids);
    return ids;
  }

  static void _walk(Object? node, Set<String> ids) {
    if (node is String) {
      final parsed = _parse(node);
      if (parsed != null) ids.add(parsed.actionId);
    } else if (node is Map) {
      for (final value in node.values) {
        _walk(value, ids);
      }
    } else if (node is List) {
      for (final value in node) {
        _walk(value, ids);
      }
    }
  }

  /// Returns a deep copy of [node] with every placeholder replaced using
  /// [results] (action ID → result map).
  ///
  /// Throws [RefResolutionException] if a referenced result or path is
  /// missing — the engine maps this to a scheduling decision.
  static Object? resolve(Object? node, Map<String, dynamic> results) {
    if (node is String) {
      final parsed = _parse(node);
      if (parsed == null) return node;
      if (!results.containsKey(parsed.actionId)) {
        throw RefResolutionException(
          'No result available for action ${parsed.actionId}',
        );
      }
      return _dig(results[parsed.actionId], parsed.path, node);
    }
    if (node is Map) {
      return <String, dynamic>{
        for (final entry in node.entries)
          entry.key as String: resolve(entry.value, results),
      };
    }
    if (node is List) {
      return node.map((v) => resolve(v, results)).toList();
    }
    return node;
  }

  static _ParsedRef? _parse(String value) {
    if (!value.startsWith(_prefix)) return null;
    final body = value.substring(_prefix.length);
    final sep = body.indexOf(':');
    if (sep == -1) return _ParsedRef(body, '');
    return _ParsedRef(body.substring(0, sep), body.substring(sep + 1));
  }

  static Object? _dig(Object? result, String path, String original) {
    if (path.isEmpty) return result;
    Object? current = result;
    for (final segment in path.split('.')) {
      if (current is Map && current.containsKey(segment)) {
        current = current[segment];
      } else {
        throw RefResolutionException(
          "Path '$path' not found in dependency result for ref '$original'",
        );
      }
    }
    return current;
  }
}

class _ParsedRef {
  const _ParsedRef(this.actionId, this.path);
  final String actionId;
  final String path;
}

/// A `$ref` placeholder could not be substituted.
class RefResolutionException implements Exception {
  const RefResolutionException(this.message);
  final String message;

  @override
  String toString() => 'RefResolutionException: $message';
}
