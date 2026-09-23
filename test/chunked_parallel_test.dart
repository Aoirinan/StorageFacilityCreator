import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:sfcapp/utils/chunked_parallel.dart';

void main() {
  test('a chunk runs together, never more than chunkSize at once, results in order', () async {
    var inFlight = 0;
    var peak = 0;
    final gates = <int, Completer<void>>{};
    final started = <int>[];

    final done = mapInChunks<int, int>(
      List.generate(7, (i) => i),
      (i) async {
        started.add(i);
        inFlight++;
        if (inFlight > peak) peak = inFlight;
        final gate = gates[i] = Completer<void>();
        await gate.future;
        inFlight--;
        return i * 10;
      },
      chunkSize: 3,
    );

    await Future<void>.delayed(Duration.zero);
    // All of the first chunk started before any finished. The loop this
    // replaced awaited one ledger sum at a time.
    expect(started, [0, 1, 2]);

    // Finish out of order; the next chunk waits for the whole first one.
    gates[2]!.complete();
    gates[0]!.complete();
    await Future<void>.delayed(Duration.zero);
    expect(started, [0, 1, 2]);
    gates[1]!.complete();

    for (var round = 0; round < 10 && started.length < 7; round++) {
      await Future<void>.delayed(Duration.zero);
      for (final i in started) {
        if (!gates[i]!.isCompleted) gates[i]!.complete();
      }
    }

    expect(await done, [0, 10, 20, 30, 40, 50, 60]);
    expect(peak, 3);
  });

  test('an error fails the whole call', () async {
    await expectLater(
      mapInChunks<int, int>([1, 2, 3], (i) async {
        if (i == 2) throw StateError('ledger read failed');
        return i;
      }),
      throwsStateError,
    );
  });

  test('an empty list returns an empty list', () async {
    expect(await mapInChunks<int, int>([], (i) async => i), isEmpty);
  });
}
