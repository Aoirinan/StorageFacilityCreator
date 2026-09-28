import 'package:flutter_test/flutter_test.dart';
import 'package:sfcapp/models/ledger_entry_model.dart';
import 'package:sfcapp/services/recurring_charges_service.dart';

/// This guard is the only thing standing between a facility and a second month
/// of rent on every tenant. It decides whether the month is already billed, and
/// the caller acts on a "no" by posting a charge.
void main() {
  final september = DateTime(2026, 9, 1);

  LedgerEntry entry({
    required DateTime entryDate,
    LedgerEntryType type = LedgerEntryType.rentCharge,
    LedgerEntryStatus status = LedgerEntryStatus.posted,
    Map<String, dynamic>? metadata,
  }) {
    return LedgerEntry(
      id: 'e1',
      tenantId: 't1',
      facilityId: 'f1',
      type: type,
      amount: 150,
      entryDate: entryDate,
      status: status,
      metadata: metadata ??
          {
            'recurringCharge': true,
            'chargeType': 'monthlyRent',
            'month': entryDate.month,
            'year': entryDate.year,
          },
      createdAt: entryDate,
      createdBy: 'system',
    );
  }

  group('hasPostedRecurringRentCharge', () {
    test('recognises the month already billed', () {
      expect(
        RecurringChargesService.hasPostedRecurringRentCharge(
          [entry(entryDate: DateTime(2026, 9, 1))],
          september,
        ),
        isTrue,
      );
    });

    test('the month is 1-based, matching what the scheduled job writes', () {
      // rentChargeJob stores getMonth() + 1. If this side ever compared a
      // 0-based month the two paths would each bill September.
      final posted = entry(
        entryDate: DateTime(2026, 9, 15),
        metadata: {
          'recurringCharge': true,
          'chargeType': 'monthlyRent',
          'month': 9,
          'year': 2026,
        },
      );
      expect(
        RecurringChargesService.hasPostedRecurringRentCharge(
            [posted], september),
        isTrue,
      );
    });

    test('a server charge dated 00:00 UTC on the 1st counts in US time zones',
        () {
      // The scheduled job dated September's charge 2026-09-01T00:00Z. In
      // Central time that is 7 PM on August 31, which is what the app reads
      // back. It is still September's charge, and must stop a second one.
      final posted = entry(
        entryDate: DateTime(2026, 8, 31, 19),
        metadata: {
          'recurringCharge': true,
          'chargeType': 'monthlyRent',
          'month': 9,
          'year': 2026,
        },
      );
      expect(
        RecurringChargesService.hasPostedRecurringRentCharge(
            [posted], september),
        isTrue,
      );
    });

    test('a different month does not count', () {
      expect(
        RecurringChargesService.hasPostedRecurringRentCharge(
          [entry(entryDate: DateTime(2026, 8, 1))],
          september,
        ),
        isFalse,
      );
    });

    test('a voided charge leaves the month unbilled', () {
      // Voiding is how a wrong charge is undone. If a voided entry still
      // counted, the corrected charge could never be posted.
      expect(
        RecurringChargesService.hasPostedRecurringRentCharge(
          [
            entry(
              entryDate: DateTime(2026, 9, 1),
              status: LedgerEntryStatus.voided,
            )
          ],
          september,
        ),
        isFalse,
      );
    });

    test('another kind of charge in the same month does not count', () {
      expect(
        RecurringChargesService.hasPostedRecurringRentCharge(
          [
            entry(
              entryDate: DateTime(2026, 9, 3),
              type: LedgerEntryType.lateFee,
            )
          ],
          september,
        ),
        isFalse,
      );
    });

    test('a one-off rent charge does not count as the recurring one', () {
      expect(
        RecurringChargesService.hasPostedRecurringRentCharge(
          [
            entry(
              entryDate: DateTime(2026, 9, 3),
              metadata: {'chargeType': 'monthlyRent', 'month': 9, 'year': 2026},
            )
          ],
          september,
        ),
        isFalse,
      );
    });

    test('an entry with no metadata does not count', () {
      expect(
        RecurringChargesService.hasPostedRecurringRentCharge(
          [entry(entryDate: DateTime(2026, 9, 3), metadata: const {})],
          september,
        ),
        isFalse,
      );
    });

    test('an empty ledger means the month is unbilled', () {
      expect(
        RecurringChargesService.hasPostedRecurringRentCharge([], september),
        isFalse,
      );
    });
  });

  group('rentChargeAlreadyPosted', () {
    test('reports what the ledger says when the read succeeds', () async {
      expect(
        await RecurringChargesService.rentChargeAlreadyPosted(
          targetDate: september,
          loadEntries: () async => [entry(entryDate: DateTime(2026, 9, 1))],
        ),
        isTrue,
      );
      expect(
        await RecurringChargesService.rentChargeAlreadyPosted(
          targetDate: september,
          loadEntries: () async => [],
        ),
        isFalse,
      );
    });

    test('a failed read says the charge is present, so the tenant is skipped',
        () async {
      // This is the whole point. Returning false here meant a Firestore
      // hiccup posted a second month of rent to every tenant in the facility,
      // on a real balance, collectable by autopay.
      expect(
        await RecurringChargesService.rentChargeAlreadyPosted(
          targetDate: september,
          loadEntries: () async => throw Exception('permission-denied'),
        ),
        isTrue,
      );
    });

    test('a read that fails synchronously is caught too', () async {
      expect(
        await RecurringChargesService.rentChargeAlreadyPosted(
          targetDate: september,
          loadEntries: () => throw StateError('offline'),
        ),
        isTrue,
      );
    });
  });
}
