import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:sfcapp/utils/single_flight.dart';

void main() {
  test('concurrent callers for one key share a single load', () async {
    // The bug this exists for: the dashboard, sidebar, banner and route guard
    // each ran the whole facility-list chain at the same time on a cold load.
    final flight = SingleFlight<String, List<String>>();
    final gate = Completer<List<String>>();
    var calls = 0;
    Future<List<String>> loader() {
      calls += 1;
      return gate.future;
    }

    final a = flight.run('uid-1|false', loader);
    final b = flight.run('uid-1|false', loader);
    expect(flight.isInFlight('uid-1|false'), isTrue);
    gate.complete(['Keepsake']);

    expect(await a, ['Keepsake']);
    expect(identical(await a, await b), isTrue);
    expect(calls, 1);
  });

  test('a call made after the first one settles loads again', () async {
    // De-duplication only: nothing is cached once the call is done.
    final flight = SingleFlight<String, int>();
    var calls = 0;
    Future<int> loader() async => ++calls;

    expect(await flight.run('k', loader), 1);
    expect(flight.isInFlight('k'), isFalse);
    expect(await flight.run('k', loader), 2);
    expect(calls, 2);
  });

  test('different keys never share, so one account cannot get another\'s list', () async {
    final flight = SingleFlight<String, String>();
    final gateA = Completer<String>();
    final gateB = Completer<String>();

    final a = flight.run('uid-A', () => gateA.future);
    final b = flight.run('uid-B', () => gateB.future);
    gateB.complete('B facilities');
    gateA.complete('A facilities');

    expect(await a, 'A facilities');
    expect(await b, 'B facilities');
  });

  test('an error reaches every waiter and frees the slot for a retry', () async {
    final flight = SingleFlight<String, int>();
    final gate = Completer<int>();
    var calls = 0;
    Future<int> failing() {
      calls += 1;
      return gate.future;
    }

    final a = flight.run('k', failing);
    final b = flight.run('k', failing);
    gate.completeError(StateError('permission-denied'));

    await expectLater(a, throwsStateError);
    await expectLater(b, throwsStateError);
    expect(calls, 1);
    expect(flight.isInFlight('k'), isFalse);

    expect(await flight.run('k', () async => 7), 7);
  });

  test('a loader that throws synchronously is reported, not leaked', () async {
    final flight = SingleFlight<String, int>();
    await expectLater(
      flight.run('k', () => throw StateError('boom')),
      throwsStateError,
    );
    expect(flight.isInFlight('k'), isFalse);
  });

  test('clear lets the next caller start afresh; existing waiters still finish', () async {
    final flight = SingleFlight<String, int>();
    final first = Completer<int>();
    var calls = 0;

    final before = flight.run('k', () {
      calls += 1;
      return first.future;
    });
    flight.clear();
    final after = flight.run('k', () async {
      calls += 1;
      return 2;
    });

    first.complete(1);
    expect(await before, 1);
    expect(await after, 2);
    expect(calls, 2);
    // The first call settling must not evict the newer entry's bookkeeping.
    expect(flight.isInFlight('k'), isFalse);
  });
}
