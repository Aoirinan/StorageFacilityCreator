import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sfcapp/models/payment_model.dart';
import 'package:sfcapp/models/security_deposit_model.dart';

// A tenant's $25 move-in deposit, paid by check. All names and numbers are
// made up.
void main() {
  final received = SecurityDeposit.noonUtc(DateTime(2026, 9, 1));

  SecurityDeposit held() => SecurityDeposit(
        amount: 25,
        receivedDate: received,
        method: PaymentMethod.check,
        reference: '1234',
        note: 'Covers Unit 12',
        recordedAt: DateTime.utc(2026, 9, 28, 15),
        recordedBy: 'owner-1',
      );

  test('a held deposit survives the round trip through Firestore', () {
    final map = held().toMap();
    expect(map['amount'], 25.0);
    expect(map['receivedDate'], Timestamp.fromDate(received));
    expect(map['method'], 'check');
    expect(map['reference'], '1234');
    expect(map['note'], 'Covers Unit 12');
    expect(map['status'], 'held');
    expect(map['recordedBy'], 'owner-1');
    // Nothing settlement-related is written until it is settled.
    expect(map.containsKey('settledAt'), isFalse);
    expect(map.containsKey('appliedAmount'), isFalse);
    expect(map.containsKey('refundedAmount'), isFalse);

    final back = SecurityDeposit.fromMap(map);
    expect(back.amount, 25);
    // Timestamps read back in local time, as every model here reads them.
    expect(back.receivedDate!.toUtc(), received);
    expect(back.method, PaymentMethod.check);
    expect(back.reference, '1234');
    expect(back.note, 'Covers Unit 12');
    expect(back.isHeld, isTrue);
    expect(back.recordedAt!.toUtc(), DateTime.utc(2026, 9, 28, 15));
    expect(back.recordedBy, 'owner-1');
    expect(back.summary, '\$25.00 held · received 9/1/2026 · Check #1234');
  });

  test('a settled deposit keeps how it was split', () {
    final settled = held().copyWith(
      status: SecurityDepositStatus.settled,
      settledAt: DateTime.utc(2026, 10, 3, 12),
      settledBy: 'owner-1',
      appliedAmount: 10,
      refundedAmount: 15,
      refundMethod: PaymentMethod.cash,
      appliedLedgerEntryId: 'ledger-1',
    );
    final back = SecurityDeposit.fromMap(settled.toMap());
    expect(back.isHeld, isFalse);
    expect(back.settledAt!.toUtc(), DateTime.utc(2026, 10, 3, 12));
    expect(back.settledBy, 'owner-1');
    expect(back.appliedAmount, 10);
    expect(back.refundedAmount, 15);
    expect(back.refundMethod, PaymentMethod.cash);
    expect(back.refundReference, isNull);
    expect(back.appliedLedgerEntryId, 'ledger-1');
    expect(back.summary, 'Settled 10/3/2026: \$10.00 applied, \$15.00 refunded');
  });

  test('missing fields read as held with the date unknown', () {
    // The least a record can hold: an amount. Written by hand or by an
    // older build, nothing else may be there.
    final back = SecurityDeposit.fromMap({'amount': 25});
    expect(back.amount, 25);
    expect(back.receivedDate, isNull);
    expect(back.method, PaymentMethod.cash);
    expect(back.reference, isNull);
    expect(back.note, isNull);
    expect(back.isHeld, isTrue);
    expect(back.settledAt, isNull);
    expect(back.appliedAmount, isNull);
    expect(back.summary, '\$25.00 held · Cash');
    // toMap writes the date as an explicit null so "unknown" is visible in
    // the console, and blank strings are dropped rather than stored.
    final map = SecurityDeposit(
      amount: 25,
      method: PaymentMethod.other,
      reference: '  ',
      note: '',
    ).toMap();
    expect(map['receivedDate'], isNull);
    expect(map.containsKey('reference'), isFalse);
    expect(map.containsKey('note'), isFalse);
  });

  test('an unknown status reads as held; only "settled" settles', () {
    expect(SecurityDeposit.fromMap({'amount': 25, 'status': 'settled'}).isHeld, isFalse);
    expect(SecurityDeposit.fromMap({'amount': 25, 'status': 'refunded'}).isHeld, isTrue);
    expect(SecurityDeposit.fromMap({'amount': 25, 'status': 7}).isHeld, isTrue);
  });

  test('amounts are kept to cents', () {
    expect(SecurityDeposit.toCents(24.999), 25.0);
    expect(SecurityDeposit.toCents(10.004), 10.0);
    expect(SecurityDeposit.toCents(10.006), 10.01);
    expect(SecurityDeposit.toCents(0.1 + 0.2), 0.3);
    final map = SecurityDeposit(amount: 24.999, method: PaymentMethod.cash).toMap();
    expect(map['amount'], 25.0);
    expect(SecurityDeposit.fromMap({'amount': 24.999}).amount, 25.0);
    // Integers stored by hand read as doubles.
    expect(SecurityDeposit.fromMap({'amount': 25}).amount, isA<double>());
  });

  test('a date is stored at noon UTC for the day it names', () {
    final noon = SecurityDeposit.noonUtc(DateTime(2026, 9, 1, 23, 30));
    expect(noon, DateTime.utc(2026, 9, 1, 12));
    expect(noon.isUtc, isTrue);
  });
}
