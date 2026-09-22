import 'package:flutter_test/flutter_test.dart';
import 'package:sfcapp/utils/invoice_charge_selection.dart';

SelectableCharge charge(
  String id, {
  double amount = 120,
  double? allocated,
  bool isCharge = true,
  bool isActive = true,
}) {
  return SelectableCharge(
    id: id,
    isCharge: isCharge,
    isActive: isActive,
    amount: amount,
    allocatedAmount: allocated,
  );
}

void main() {
  group('selectableChargeIds', () {
    test('an unpaid charge is available', () {
      final ids = selectableChargeIds(
        charges: [charge('rent-sep')],
        idsOnLiveInvoices: const {},
      );
      expect(ids, ['rent-sep']);
    });

    test('a charge already on a live invoice is not offered again', () {
      // The double-billing case: September rent was invoiced, so generating
      // another invoice must not pick it up a second time.
      final ids = selectableChargeIds(
        charges: [charge('rent-sep'), charge('late-fee', amount: 30)],
        idsOnLiveInvoices: const {'rent-sep'},
      );
      expect(ids, ['late-fee']);
    });

    test('a settled charge is not offered again', () {
      final ids = selectableChargeIds(
        charges: [charge('rent-sep', amount: 120, allocated: 120)],
        idsOnLiveInvoices: const {},
      );
      expect(ids, isEmpty);
    });

    test('a part-paid charge is still available for the remainder', () {
      final ids = selectableChargeIds(
        charges: [charge('rent-sep', amount: 120, allocated: 40)],
        idsOnLiveInvoices: const {},
      );
      expect(ids, ['rent-sep']);
    });

    test('a charge released by voiding its invoice can be billed again', () {
      // Voiding is how an operator corrects a mistaken invoice; the charge
      // still needs billing, so it must come back.
      final ids = selectableChargeIds(
        charges: [charge('rent-sep')],
        idsOnLiveInvoices: const {}, // the voided invoice no longer covers it
      );
      expect(ids, ['rent-sep']);
    });

    test('payments and voided entries are never invoiced', () {
      final ids = selectableChargeIds(
        charges: [
          charge('payment', isCharge: false),
          charge('voided-fee', isActive: false),
          charge('rent-sep'),
        ],
        idsOnLiveInvoices: const {},
      );
      expect(ids, ['rent-sep']);
    });

    test('an explicit selection still respects every other rule', () {
      final ids = selectableChargeIds(
        charges: [
          charge('rent-sep'),
          charge('already-billed'),
          charge('settled', allocated: 120),
        ],
        idsOnLiveInvoices: const {'already-billed'},
        onlyThese: ['rent-sep', 'already-billed', 'settled'],
      );
      expect(ids, ['rent-sep']);
    });

    test('an explicit selection cannot reach a charge it did not name', () {
      final ids = selectableChargeIds(
        charges: [charge('rent-sep'), charge('late-fee', amount: 30)],
        idsOnLiveInvoices: const {},
        onlyThese: ['late-fee'],
      );
      expect(ids, ['late-fee']);
    });
  });

  group('chargeIsSettled', () {
    test('unallocated is not settled', () {
      expect(chargeIsSettled(amount: 120), isFalse);
    });

    test('fully or over allocated is settled', () {
      expect(chargeIsSettled(amount: 120, allocatedAmount: 120), isTrue);
      expect(chargeIsSettled(amount: 120, allocatedAmount: 130), isTrue);
    });

    test('part allocation is not settled', () {
      expect(chargeIsSettled(amount: 120, allocatedAmount: 119.99), isFalse);
    });
  });
}
