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
      createdAt: DateTime(2026, 9, 25),
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

  test('one row per payment even when a payments doc points at it', () {
    // Record payment writes a payments doc and a ledger row linked by
    // metadata.paymentId; only the ledger is read, so it is listed once.
    final list = receivedPayments([
      _row('l1', LedgerEntryType.payment, -55, DateTime(2026, 7, 9), metadata: {
        'paymentMethod': 'check',
        'paymentId': 'pay-1',
        'reference': '880',
      }),
    ]);
    expect(list, hasLength(1));
    expect(list.single.label, 'Check #880');
  });

  test('the method comes from the row, or Stripe for a webhook row, else plain Payment', () {
    final list = receivedPayments([
      _row('s1', LedgerEntryType.payment, -30, DateTime(2026, 6, 3), metadata: {'paymentIntentId': 'pi_test_1'}),
      _row('m1', LedgerEntryType.payment, -30, DateTime(2026, 6, 2), metadata: {'paymentMethod': 'zelle', 'reference': '  '}),
      _row('n1', LedgerEntryType.payment, -30, DateTime(2026, 6, 1)),
    ]);
    expect(list.map((p) => p.label), ['Stripe', 'Zelle', 'Payment']);
  });
}
