/// Holds one value and rebuilds it only when its inputs change.
///
/// Written for a specific and expensive mistake: a `FutureBuilder` whose
/// `future:` is constructed inline in `build()`. Flutter rebuilds on every
/// `setState`, so a future created there re-runs its work on every keystroke
/// in a search box. When that work is two Firestore collection reads, a
/// facility with 86 units bills and waits for roughly ninety document reads
/// per character typed, and the screen stops responding.
///
/// Keep an instance in the State, key it on whatever the work actually
/// depends on, and the work runs when those inputs change rather than when
/// the widget happens to repaint.
class KeyedMemo<T extends Object> {
  String? _key;
  T? _value;

  /// Returns the memoised value for [key], calling [create] only when [key]
  /// differs from the last one, or nothing has been created yet.
  T call(String key, T Function() create) {
    if (_key != key || _value == null) {
      _key = key;
      _value = create();
    }
    return _value!;
  }

  /// Drops the cached value so the next call recreates it. For an explicit
  /// refresh, where the inputs have not changed but the answer may have.
  void invalidate() {
    _key = null;
    _value = null;
  }

  /// Whether anything is currently cached. Exposed for tests.
  bool get hasValue => _value != null;
}

extension KeyedFutureMemo<R> on KeyedMemo<Future<R>> {
  /// [call] for a future whose result may not be worth keeping.
  ///
  /// Once the future completes, a result [keep] rejects, or an error, is
  /// forgotten, so the next call for the same key reads again. The caller
  /// still gets this future, so what is on screen does not change. Without
  /// this, a transient failure was held until the key changed.
  Future<R> callKeeping(
    String key,
    Future<R> Function() create, {
    required bool Function(R value) keep,
  }) {
    return call(key, () {
      final created = create();
      void forget() {
        // Only this future: a newer key may already have replaced it.
        if (identical(_value, created)) invalidate();
      }

      created.then((value) {
        if (!keep(value)) forget();
      }, onError: (Object _) => forget());
      return created;
    });
  }
}
