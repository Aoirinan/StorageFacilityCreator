import 'package:flutter_test/flutter_test.dart';
import 'package:sfcapp/utils/keyed_memo.dart';

void main() {
  test('creates the value once and reuses it for the same key', () {
    // The bug this exists for: a FutureBuilder rebuilt by every keystroke,
    // re-running two Firestore collection reads each time.
    final memo = KeyedMemo<Object>();
    var calls = 0;
    Object create() {
      calls += 1;
      return Object();
    }

    final first = memo('fac1|86|0', create);
    for (var i = 0; i < 20; i++) {
      expect(identical(memo('fac1|86|0', create), first), isTrue);
    }
    expect(calls, 1);
  });

  test('recreates when the inputs actually change', () {
    final memo = KeyedMemo<Object>();
    var calls = 0;
    Object create() {
      calls += 1;
      return Object();
    }

    final a = memo('fac1|86|0', create);
    final b = memo('fac1|86|1', create); // a tenant moved in
    final c = memo('fac2|12|3', create); // different facility
    expect(calls, 3);
    expect(identical(a, b), isFalse);
    expect(identical(b, c), isFalse);
  });

  test('invalidate forces the next call to recreate', () {
    final memo = KeyedMemo<Object>();
    var calls = 0;
    Object create() {
      calls += 1;
      return Object();
    }

    memo('same', create);
    memo('same', create);
    expect(calls, 1);

    memo.invalidate();
    expect(memo.hasValue, isFalse);
    memo('same', create);
    expect(calls, 2);
  });

  test('switching away and back does recreate, rather than serving a stale value', () {
    // Only the most recent key is held, on purpose: this is a one-slot memo,
    // not a cache, so it cannot serve a value from an old facility.
    final memo = KeyedMemo<Object>();
    var calls = 0;
    Object create() {
      calls += 1;
      return Object();
    }

    memo('fac1', create);
    memo('fac2', create);
    memo('fac1', create);
    expect(calls, 3);
  });

  test('starts empty', () {
    expect(KeyedMemo<Object>().hasValue, isFalse);
  });
}
