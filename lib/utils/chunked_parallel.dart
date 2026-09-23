/// Runs [task] over [items], at most [chunkSize] at a time, and returns the
/// results in the same order as [items].
///
/// For independent reads, one per item. Awaiting them one after another cost a
/// full round trip each: the dashboard's Top Delinquent list summed one ledger
/// per overdue tenant, in series. Firing them all at once has no bound on a
/// large facility. Chunks keep both in check.
///
/// An error from [task] fails the whole call, as with [Future.wait]. Catch
/// inside [task] when one bad item should not sink the rest.
Future<List<R>> mapInChunks<T, R>(
  List<T> items,
  Future<R> Function(T item) task, {
  int chunkSize = 10,
}) async {
  assert(chunkSize > 0);
  final results = <R>[];
  for (var start = 0; start < items.length; start += chunkSize) {
    final end =
        start + chunkSize < items.length ? start + chunkSize : items.length;
    results.addAll(await Future.wait(items.sublist(start, end).map(task)));
  }
  return results;
}
