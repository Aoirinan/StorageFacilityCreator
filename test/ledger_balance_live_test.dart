import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sfcapp/models/ledger_entry_model.dart';
import 'package:sfcapp/providers/ledger_provider.dart';

LedgerEntry _entry(String id, double amount, LedgerEntryStatus status) =>
    LedgerEntry(
      id: id,
      tenantId: 't1',
      facilityId: 'f1',
      type: amount < 0 ? LedgerEntryType.payment : LedgerEntryType.rentCharge,
      amount: amount,
      entryDate: DateTime(2026, 9, 1),
      status: status,
      createdAt: DateTime(2026, 9, 1),
      createdBy: 'owner',
    );

void main() {
  const params = LedgerParams(tenantId: 't1', facilityId: 'f1');

  test('ledger balance follows the entries as they change', () async {
    final source = StreamController<List<LedgerEntry>>();
    final container = ProviderContainer(overrides: [
      ledgerStreamProvider(params).overrideWith((ref) => source.stream),
    ]);
    addTearDown(container.dispose);
    addTearDown(() => unawaited(source.close()));
    final sub = container.listen(ledgerBalanceProvider(params), (_, __) {});
    addTearDown(sub.close);

    Future<void> settle() async {
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
    }

    source.add([_entry('r', 1, LedgerEntryStatus.posted)]);
    await settle();
    expect(container.read(ledgerBalanceProvider(params)).value, 1.0);

    // Voiding the only charge must bring the header to zero straight away;
    // before, it kept showing $1.00 until the screen was reopened.
    source.add([_entry('r', 1, LedgerEntryStatus.voided)]);
    await settle();
    expect(container.read(ledgerBalanceProvider(params)).value, 0.0);
  });

  test('only posted entries count, payments are negative', () {
    expect(
      sumPostedLedgerEntries([
        _entry('a', 65, LedgerEntryStatus.posted),
        _entry('b', -40, LedgerEntryStatus.posted),
        _entry('c', 30, LedgerEntryStatus.voided),
        _entry('d', 10, LedgerEntryStatus.pending),
      ]),
      25.0,
    );
  });
}
