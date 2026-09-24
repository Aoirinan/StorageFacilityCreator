import 'dart:async';

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

  group('callKeeping', () {
    test('keeps a result that passes, like call', () async {
      final memo = KeyedMemo<Future<int>>();
      var calls = 0;
      Future<int> create() async => ++calls * 10;

      expect(await memo.callKeeping('k', create, keep: (v) => v > 0), 10);
      expect(await memo.callKeeping('k', create, keep: (v) => v > 0), 10);
      expect(calls, 1);
    });

    test('shows a rejected result once, then reads again for the same key', () async {
      // The facility card case: a failed read comes back as zeros. Before,
      // the memo held it until the facility's mirrored counts changed.
      final memo = KeyedMemo<Future<int>>();
      final results = [0, 72];
      var calls = 0;
      Future<int> create() async => results[calls++];

      expect(await memo.callKeeping('fac1|72|78', create, keep: (v) => v == 72), 0);
      expect(memo.hasValue, isFalse);
      expect(await memo.callKeeping('fac1|72|78', create, keep: (v) => v == 72), 72);
      expect(await memo.callKeeping('fac1|72|78', create, keep: (v) => v == 72), 72);
      expect(calls, 2);
    });

    test('forgets a future that failed', () async {
      final memo = KeyedMemo<Future<int>>();
      var calls = 0;
      Future<int> create() async {
        calls++;
        if (calls == 1) throw StateError('offline');
        return 5;
      }

      await expectLater(
        memo.callKeeping('k', create, keep: (_) => true),
        throwsStateError,
      );
      expect(await memo.callKeeping('k', create, keep: (_) => true), 5);
      expect(calls, 2);
    });

    test('an old rejected result does not drop a newer key', () async {
      final memo = KeyedMemo<Future<int>>();
      final old = Completer<int>();
      final oldFuture =
          memo.callKeeping('old', () => old.future, keep: (v) => v > 0);
      final newer =
          memo.callKeeping('new', () async => 7, keep: (v) => v > 0);
      expect(await newer, 7);

      old.complete(0);
      await oldFuture;
      expect(memo.hasValue, isTrue);
      var recreated = false;
      unawaited(memo.callKeeping('new', () async {
        recreated = true;
        return 8;
      }, keep: (v) => v > 0));
      expect(recreated, isFalse);
    });
  });
}
