import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sfcapp/models/ledger_entry_model.dart';
import 'package:sfcapp/models/transfer_model.dart';
import 'package:sfcapp/providers/ledger_provider.dart';
import 'package:sfcapp/services/transfer_service.dart';

/// A tenant's balance is the signed sum of their posted ledger amounts:
/// charges positive, payments and credits negative. The transfer credit for
/// the unit left used to be written positive, so a transfer that should have
/// left the tenant $30 ahead left them $30 behind. These tests pin the sign.
///
/// Fake data throughout: this repository is public.
final _day = DateTime(2026, 9, 16);

TransferModel _transfer({
  double from = 50,
  double to = 75,
}) =>
    TransferModel(
      id: 'transfer-1',
      facilityId: 'f1',
      tenantId: 't1',
      fromUnitId: 'u-12',
      toUnitId: 'u-14',
      fromUnitNumber: '12',
      toUnitNumber: '14',
      status: TransferStatus.pending,
      transferDate: _day,
      fromUnitProratedRent: from,
      toUnitProratedRent: to,
      fromUnitRate: 100,
      toUnitRate: 150,
      netAmount: to - from,
      ledgerEntryIds: const [],
      createdAt: _day,
      createdBy: 'owner',
    );

LedgerEntry _posted(TransferLedgerLine line, String id) => LedgerEntry(
      id: id,
      tenantId: 't1',
      facilityId: 'f1',
      type: line.type,
      amount: line.amount,
      description: line.description,
      entryDate: _day,
      dueDate: _day,
      status: LedgerEntryStatus.posted,
      metadata: line.metadata,
      createdAt: _day,
      createdBy: 'owner',
    );

void main() {
  group('TransferService.ledgerLines', () {
    test('the credit for the unit left is negative, the charge for the unit taken positive', () {
      final lines = TransferService.ledgerLines(_transfer(from: 50, to: 75));
      expect(lines, hasLength(2));

      final credit = lines[0];
      expect(credit.type, LedgerEntryType.credit);
      expect(credit.amount, -50);
      expect(credit.description, 'Transfer refund: 12 (prorated)');
      expect(credit.metadata['type'], 'transfer_refund');
      expect(credit.metadata['unitId'], 'u-12');
      expect(credit.metadata['unitNumber'], '12');
      expect(credit.metadata['transferId'], 'transfer-1');

      final charge = lines[1];
      expect(charge.type, LedgerEntryType.rentCharge);
      expect(charge.amount, 75);
      expect(charge.description, 'Transfer charge: 14 (prorated)');
      expect(charge.metadata['type'], 'transfer_charge');
      expect(charge.metadata['unitId'], 'u-14');
      expect(charge.metadata['unitNumber'], '14');
      expect(charge.metadata['transferId'], 'transfer-1');
    });

    test('the entries sum to netAmount whichever way the transfer goes', () {
      // Up to a dearer unit: the tenant owes the difference.
      final up = TransferService.ledgerLines(_transfer(from: 50, to: 75));
      expect(up.fold(0.0, (sum, l) => sum + l.amount), 25);
      // Down to a cheaper unit: the tenant is owed the difference. Written
      // positive, this summed to +125 and billed both units.
      final down = TransferService.ledgerLines(_transfer(from: 75, to: 50));
      expect(down.fold(0.0, (sum, l) => sum + l.amount), -25);
      expect(_transfer(from: 75, to: 50).netAmount, -25);
    });

    test('the balance rule the app uses moves by netAmount, not by both rents', () {
      // Unit 12 was billed $100 on the 1st. Moving to unit 14 on the 16th
      // gives back $50 of it and charges $75 for 14: the tenant owes $125.
      final alreadyBilled = LedgerEntry(
        id: 'rent-sept',
        tenantId: 't1',
        facilityId: 'f1',
        type: LedgerEntryType.rentCharge,
        amount: 100,
        entryDate: DateTime(2026, 9, 1),
        status: LedgerEntryStatus.posted,
        createdAt: DateTime(2026, 9, 1),
        createdBy: 'owner',
      );
      final lines = TransferService.ledgerLines(_transfer(from: 50, to: 75));
      final entries = [
        alreadyBilled,
        for (var i = 0; i < lines.length; i++) _posted(lines[i], 'transfer-line-$i'),
      ];
      expect(sumPostedLedgerEntries(entries), 125);
    });

    test('a zero amount posts no entry; the guard is on the magnitude', () {
      final noCredit = TransferService.ledgerLines(_transfer(from: 0, to: 75));
      expect(noCredit.map((l) => l.type), [LedgerEntryType.rentCharge]);
      expect(noCredit.single.amount, 75);

      final noCharge = TransferService.ledgerLines(_transfer(from: 50, to: 0));
      expect(noCharge.map((l) => l.type), [LedgerEntryType.credit]);
      expect(noCharge.single.amount, -50);

      expect(TransferService.ledgerLines(_transfer(from: 0, to: 0)), isEmpty);
    });

    test('completeTransfer posts exactly these lines', () {
      final source = File('lib/services/transfer_service.dart').readAsStringSync();
      expect(source, contains('for (final line in ledgerLines(transfer))'));
      expect(source, contains('amount: line.amount,'));
      // The old inline write, positive.
      expect(source, isNot(contains('amount: transfer.fromUnitProratedRent')));
    });
  });
}
