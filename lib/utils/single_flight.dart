/// Shares one in-flight call per key between everyone who asks for it at the
/// same time.
///
/// Written for the facility list: on a cold load the dashboard, the sidebar,
/// the subscription banner and the route guard all asked for the same user's
/// facilities within a few milliseconds, and each ran its own chain of
/// Firestore round trips because the 2-minute cache only fills once a call
/// finishes.
///
/// Key it on everything the answer depends on (at least the signed-in uid), so
/// a caller can never be handed another account's in-flight result. Nothing is
/// kept once the call settles: this de-duplicates, it does not cache.
class SingleFlight<K, T> {
  final Map<K, Future<T>> _inflight = <K, Future<T>>{};

  /// Returns the call already running for [key], or starts [loader] and shares
  /// it with anyone else who asks for [key] before it settles. An error reaches
  /// every waiter and frees the slot, so the next call retries.
  Future<T> run(K key, Future<T> Function() loader) {
    final existing = _inflight[key];
    if (existing != null) return existing;

    late final Future<T> shared;
    shared = Future<T>.sync(loader).whenComplete(() {
      // Only drop our own entry: clear() may already have let a newer call in.
      if (identical(_inflight[key], shared)) _inflight.remove(key);
    });
    _inflight[key] = shared;
    return shared;
  }

  /// Whether a call for [key] is currently running. Exposed for tests.
  bool isInFlight(K key) => _inflight.containsKey(key);

  /// Forgets every running call, so the next [run] starts afresh. Callers
  /// already waiting still get their result.
  void clear() => _inflight.clear();
}
