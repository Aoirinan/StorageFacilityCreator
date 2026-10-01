import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:sfcapp/models/ledger_entry_model.dart';
import 'package:sfcapp/utils/received_payments.dart';

// Fake data only: this repo is public.
LedgerEntry _row(
  String id,
  LedgerEntryType type,
  double amount,
  DateTime on, {
  LedgerEntryStatus status = LedgerEntryStatus.posted,
  Map<String, dynamic>? metadata,
  DateTime? createdAt,
}) =>
    LedgerEntry(
      id: id,
      tenantId: 'tenant-1',
      facilityId: 'facility-1',
      type: type,
      amount: amount,
      entryDate: on,
      status: status,
      metadata: metadata,
      createdAt: createdAt ?? DateTime(2026, 9, 25),
      createdBy: 'owner',
    );

void main() {
  test('Enter past history payments are listed with their date and check number, newest first', () {
    final list = receivedPayments([
      _row('h1', LedgerEntryType.payment, -70, DateTime.utc(2026, 4, 3, 12), metadata: {
        'paymentMethod': 'check',
        'paymentId': 'pay-h1',
        'reference': '5101',
        'source': 'past_history',
      }),
      _row('h2', LedgerEntryType.payment, -70, DateTime.utc(2026, 5, 1, 12), metadata: {
        'paymentMethod': 'cash',
        'paymentId': 'pay-h2',
        'dateIsMonthOnly': true,
        'source': 'past_history',
      }),
      _row('c1', LedgerEntryType.rentCharge, 70, DateTime.utc(2026, 4, 1, 12)),
    ]);

    expect(list.map((p) => p.ledgerEntryId), ['h2', 'h1']);
    expect(list[1].receivedOn, DateTime.utc(2026, 4, 3, 12));
    expect(list[1].label, 'Check #5101');
    expect(list[1].amount, 70);
    expect(list[1].monthOnly, isFalse);
    expect(list[0].label, 'Cash');
    expect(list[0].monthOnly, isTrue);
  });

  test('only posted payment rows are payments received', () {
    final list = receivedPayments([
      _row('paid', LedgerEntryType.payment, -40, DateTime(2026, 8, 2)),
      _row('owed', LedgerEntryType.payment, -40, DateTime(2026, 8, 3), status: LedgerEntryStatus.pending),
      _row('undone', LedgerEntryType.payment, -40, DateTime(2026, 8, 4), status: LedgerEntryStatus.voided),
      _row('goodwill', LedgerEntryType.credit, -10, DateTime(2026, 8, 5)),
      _row('handed-back', LedgerEntryType.refund, 40, DateTime(2026, 8, 6)),
      _row('rent', LedgerEntryType.rentCharge, 40, DateTime(2026, 8, 1)),
    ]);
    expect(list.map((p) => p.ledgerEntryId), ['paid']);
  });

  test('the method comes from the row, or Stripe for a webhook row, else plain Payment', () {
    final list = receivedPayments([
      _row('s1', LedgerEntryType.payment, -30, DateTime(2026, 6, 3), metadata: {'paymentIntentId': 'pi_test_1'}),
      _row('m1', LedgerEntryType.payment, -30, DateTime(2026, 6, 2), metadata: {'paymentMethod': 'zelle', 'reference': '  '}),
      _row('n1', LedgerEntryType.payment, -30, DateTime(2026, 6, 1)),
    ]);
    expect(list.map((p) => p.label), ['Stripe', 'Zelle', 'Payment']);
  });

  test('ACH from the move-in wizard is a bank transfer, not Other', () {
    final list = receivedPayments([
      _row('a1', LedgerEntryType.payment, -30, DateTime(2026, 6, 3),
          metadata: {'paymentMethod': 'ach', 'moveInPayment': true}),
      _row('b1', LedgerEntryType.payment, -30, DateTime(2026, 6, 2), metadata: {'paymentMethod': 'bankTransfer'}),
      _row('o1', LedgerEntryType.payment, -30, DateTime(2026, 6, 1), metadata: {'paymentMethod': 'other'}),
    ]);
    expect(list.map((p) => p.label), ['Bank transfer (ACH)', 'Bank Transfer', 'Other']);
  });

  test('rows on the same instant come out in the same order whatever order they are read in', () {
    // "Month only" history payments are all the 1st at 12:00 UTC. Recorded
    // in three saves; within a save, by id.
    final sameDay = DateTime.utc(2026, 3, 1, 12);
    final rows = [
      for (var i = 0; i < 40; i++)
        _row('p${i.toString().padLeft(2, '0')}', LedgerEntryType.payment, -25, sameDay,
            metadata: {'paymentMethod': 'cash', 'dateIsMonthOnly': true, 'source': 'past_history'},
            createdAt: DateTime.utc(2026, 9, 20 + i % 3)),
    ];
    final expected = [
      for (final day in [22, 21, 20])
        for (var i = 0; i < 40; i++)
          if (20 + i % 3 == day) 'p${i.toString().padLeft(2, '0')}',
    ];
    expect(expected, hasLength(40));

    final random = Random(48);
    for (var run = 0; run < 20; run++) {
      final shuffled = [...rows]..shuffle(random);
      final ids = receivedPayments(shuffled).map((p) => p.ledgerEntryId).toList();
      expect(ids, expected, reason: 'run $run');
    }
  });
}
