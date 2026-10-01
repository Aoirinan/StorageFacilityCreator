import 'package:flutter_test/flutter_test.dart';
import 'package:sfcapp/models/ledger_entry_model.dart';
import 'package:sfcapp/utils/invoice_charge_selection.dart';

SelectableCharge charge(
  String id, {
  double amount = 120,
  double? allocated,
  bool isCharge = true,
  bool isActive = true,
  DateTime? on,
  String? description,
}) {
  return SelectableCharge(
    id: id,
    isCharge: isCharge,
    isActive: isActive,
    amount: amount,
    allocatedAmount: allocated,
    entryDate: on ?? DateTime(2026, 9, 1),
    description: description ?? id,
  );
}

const _months = [
  'January',
  'February',
  'March',
  'April',
  'May',
  'June',
  'July',
  'August',
  'September',
];

/// A fictional tenant's year so far: $130 rent posted on the first of each
/// month from January to September ($1,170), and $737 paid by check along
/// the way. The ledger balance is $433.
final _nineMonthsRent = [
  for (var m = 1; m <= 9; m++)
    charge(
      'rent-2026-${m.toString().padLeft(2, '0')}',
      amount: 130,
      on: DateTime(2026, m, 1),
      description: 'Rent - ${_months[m - 1]} 2026',
    ),
];
const _nineMonthsBalance = 1170.0 - 737.0;

List<(String, double)> _idsAndAmounts(List<OpenCharge> lines) =>
    [for (final l in lines) (l.id, l.amount)];

void main() {
  group('selectableChargeIds', () {
    test('an unpaid charge is available', () {
      final ids = selectableChargeIds(
        charges: [charge('rent-sep')],
        idsOnLiveInvoices: const {},
      );
      expect(ids, ['rent-sep']);
    });

    test('a card dispute is never offered for an invoice', () {
      // Paid through an invoice, the payment counted as rent while the
      // dispute stayed open: autopay under-charged the rent and the Ledger
      // still asked staff to collect the dispute.
      final ids = selectableChargeIds(
        charges: [
          charge('rent-sep'),
          SelectableCharge(
            id: 'dispute_du_1',
            isCharge: true,
            isActive: true,
            amount: 100,
            isCardDispute: true,
            entryDate: DateTime(2026, 9, 20),
            description: 'Card dispute',
          ),
        ],
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

  group('openChargesForInvoice', () {
    // The case seen on a live facility: nine months of rent charges, most of
    // them paid by check, and none of the payments recorded as
    // allocatedAmount on the charges. Generate Invoice offered all nine
    // months, $1,170, to a tenant who owed $433.
    test('bills the newest charges up to the ledger balance, the oldest '
        'taken in part', () {
      final lines = openChargesForInvoice(
        charges: _nineMonthsRent,
        idsOnLiveInvoices: const {},
        ledgerBalance: _nineMonthsBalance,
        liveInvoiceBalance: 0,
      );

      expect(_idsAndAmounts(lines), [
        ('rent-2026-09', 130.0),
        ('rent-2026-08', 130.0),
        ('rent-2026-07', 130.0),
        ('rent-2026-06', 43.0),
      ]);
      expect(lines.fold(0.0, (sum, l) => sum + l.amount), 433.0);
      expect(lines.last.isPartial, isTrue);
      expect(lines.last.description, 'Rent - June 2026 (balance)');
      expect(lines.first.isPartial, isFalse);
      expect(lines.first.description, 'Rent - September 2026');
    });

    test('a tenant in credit, or paid up, has nothing to invoice', () {
      for (final balance in [-250.0, 0.0]) {
        final lines = openChargesForInvoice(
          charges: _nineMonthsRent,
          idsOnLiveInvoices: const {},
          ledgerBalance: balance,
          liveInvoiceBalance: 0,
        );
        expect(lines, isEmpty, reason: 'balance $balance');
      }
    });

    test('a live invoice covering part of the balance leaves only the rest',
        () {
      // September's rent is already on a draft invoice asking $130; the
      // tenant owes $433 in all. A second invoice may bill $303: August,
      // July and $43 of June — not September again.
      final lines = openChargesForInvoice(
        charges: _nineMonthsRent,
        idsOnLiveInvoices: const {'rent-2026-09'},
        ledgerBalance: _nineMonthsBalance,
        liveInvoiceBalance: 130,
      );
      expect(_idsAndAmounts(lines), [
        ('rent-2026-08', 130.0),
        ('rent-2026-07', 130.0),
        ('rent-2026-06', 43.0),
      ]);
    });

    test('live invoices asking for the whole balance leave nothing', () {
      final lines = openChargesForInvoice(
        charges: _nineMonthsRent,
        idsOnLiveInvoices: const {'rent-2026-09'},
        ledgerBalance: 130,
        liveInvoiceBalance: 130,
      );
      expect(lines, isEmpty);
    });

    test('voided and pending charges are passed over', () {
      // The balance counts posted entries only, so a voided or pending
      // charge must not be what the balance is billed against.
      final lines = openChargesForInvoice(
        charges: [
          charge('voided-oct', amount: 130, on: DateTime(2026, 10, 1),
              isActive: false),
          charge('pending-oct', amount: 130, on: DateTime(2026, 10, 2),
              isActive: false),
          charge('rent-sep', amount: 130, on: DateTime(2026, 9, 1)),
          charge('payment', amount: -100, on: DateTime(2026, 9, 5),
              isCharge: false),
        ],
        idsOnLiveInvoices: const {},
        ledgerBalance: 30,
        liveInvoiceBalance: 0,
      );
      expect(_idsAndAmounts(lines), [('rent-sep', 30.0)]);
      expect(lines.single.description, 'rent-sep (balance)');
    });

    test('a settled charge is skipped and a part-allocated one bills its '
        'remainder', () {
      // Move-in wrote allocatedAmount: the first month is settled, the
      // second had $50 of the move-in payment put against it.
      final lines = openChargesForInvoice(
        charges: [
          charge('rent-aug', amount: 130, on: DateTime(2026, 8, 1),
              allocated: 130),
          charge('rent-sep', amount: 130, on: DateTime(2026, 9, 1),
              allocated: 50),
        ],
        idsOnLiveInvoices: const {},
        ledgerBalance: 80,
        liveInvoiceBalance: 0,
      );
      expect(_idsAndAmounts(lines), [('rent-sep', 80.0)]);
      expect(lines.single.isPartial, isFalse);
    });

    test('a whole charge for the exact balance is not marked partial', () {
      final lines = openChargesForInvoice(
        charges: [charge('rent-sep', amount: 130)],
        idsOnLiveInvoices: const {},
        ledgerBalance: 130,
        liveInvoiceBalance: 0,
      );
      expect(lines.single.isPartial, isFalse);
      expect(lines.single.description, 'rent-sep');
    });

    test('an explicit selection narrows what may be taken', () {
      final lines = openChargesForInvoice(
        charges: _nineMonthsRent,
        idsOnLiveInvoices: const {},
        ledgerBalance: _nineMonthsBalance,
        liveInvoiceBalance: 0,
        onlyThese: ['rent-2026-08', 'rent-2026-07'],
      );
      expect(_idsAndAmounts(lines), [
        ('rent-2026-08', 130.0),
        ('rent-2026-07', 130.0),
      ]);
    });

    test('charges on the same day are taken in one order however they '
        'arrive', () {
      final sameDay = [
        charge('late-fee', amount: 10, on: DateTime(2026, 9, 1)),
        charge('rent-sep', amount: 130, on: DateTime(2026, 9, 1)),
      ];
      final forwards = openChargesForInvoice(
        charges: sameDay,
        idsOnLiveInvoices: const {},
        ledgerBalance: 50,
        liveInvoiceBalance: 0,
      );
      final backwards = openChargesForInvoice(
        charges: sameDay.reversed,
        idsOnLiveInvoices: const {},
        ledgerBalance: 50,
        liveInvoiceBalance: 0,
      );
      expect(_idsAndAmounts(forwards), _idsAndAmounts(backwards));
      expect(forwards.fold(0.0, (sum, l) => sum + l.amount), 50.0);
    });

    test('cents do not leave a charge a fraction short', () {
      final lines = openChargesForInvoice(
        charges: [
          charge('a', amount: 0.1, on: DateTime(2026, 9, 3)),
          charge('b', amount: 0.2, on: DateTime(2026, 9, 2)),
          charge('c', amount: 100, on: DateTime(2026, 9, 1)),
        ],
        idsOnLiveInvoices: const {},
        ledgerBalance: 0.3,
        liveInvoiceBalance: 0,
      );
      expect(_idsAndAmounts(lines), [('a', 0.1), ('b', 0.2)]);
    });
  });

  group('nothingToInvoiceMessage', () {
    test('a tenant in credit, or paid up, owes nothing', () {
      for (final balance in [-250.0, 0.0, 0.004]) {
        expect(
          nothingToInvoiceMessage(
            ledgerBalance: balance,
            liveInvoiceBalance: 0,
          ),
          'No balance due — nothing to invoice',
          reason: 'balance $balance',
        );
      }
    });

    // The state found on a live facility: the ledger said $433 and an old
    // draft asked for $1,170. "No balance due" under a header reading
    // $433.00 gave the owner no way to see that the draft had to go first.
    test('money owed that a live invoice already asks for names the invoice',
        () {
      expect(
        nothingToInvoiceMessage(ledgerBalance: 433, liveInvoiceBalance: 1170),
        "This tenant's balance is already on an invoice: open invoices ask "
        'for \$1170.00 and the ledger balance is \$433.00. Void it or mark it '
        'paid under Rent & payments › Invoices before generating another.',
      );
    });

    // A check recorded on the ledger while the invoice it paid stays Sent:
    // next month's rent posts, ledger $130, live invoice $130.
    test('an invoice the ledger has paid but nobody marked paid is named too',
        () {
      expect(
        nothingToInvoiceMessage(ledgerBalance: 130, liveInvoiceBalance: 130),
        startsWith("This tenant's balance is already on an invoice: open "
            'invoices ask for \$130.00 and the ledger balance is \$130.00.'),
      );
    });

    test('money owed with nothing live asking for it and no charge to bill '
        'says so', () {
      expect(
        nothingToInvoiceMessage(ledgerBalance: 433, liveInvoiceBalance: 0),
        'This tenant owes \$433.00, but every charge on the ledger is already '
        'on an invoice or recorded as settled, so there is nothing to put on '
        'a new one. Check Rent & payments › Invoices.',
      );
    });
  });

  group('SelectableCharge.fromLedgerEntry', () {
    LedgerEntry entry({
      required double amount,
      LedgerEntryType type = LedgerEntryType.rentCharge,
      LedgerEntryStatus status = LedgerEntryStatus.posted,
      String? description,
      Map<String, dynamic>? metadata,
    }) =>
        LedgerEntry(
          id: 'e1',
          tenantId: 't1',
          facilityId: 'f1',
          type: type,
          amount: amount,
          description: description,
          entryDate: DateTime(2026, 9, 1),
          status: status,
          metadata: metadata,
          createdAt: DateTime(2026, 9, 1),
          createdBy: 'owner',
        );

    test('a posted charge, described by its description or else its type',
        () {
      final named = SelectableCharge.fromLedgerEntry(
        entry(amount: 130, description: 'Rent - September 2026'),
      );
      expect(named.isCharge, isTrue);
      expect(named.isActive, isTrue);
      expect(named.amount, 130);
      expect(named.entryDate, DateTime(2026, 9, 1));
      expect(named.description, 'Rent - September 2026');
      expect(named.allocatedAmount, isNull);

      final unnamed = SelectableCharge.fromLedgerEntry(
        entry(amount: 10, type: LedgerEntryType.lateFee),
      );
      expect(unnamed.description, 'Late Fee');
    });

    test('payments are not charges and voided entries are not active', () {
      final payment = SelectableCharge.fromLedgerEntry(
        entry(amount: -130, type: LedgerEntryType.payment),
      );
      expect(payment.isCharge, isFalse);

      final voided = SelectableCharge.fromLedgerEntry(
        entry(amount: 130, status: LedgerEntryStatus.voided),
      );
      expect(voided.isActive, isFalse);
    });

    test('refund and credit rows stored positive are not charges', () {
      for (final type in [
        LedgerEntryType.refund,
        LedgerEntryType.credit,
        LedgerEntryType.payment,
      ]) {
        final c =
            SelectableCharge.fromLedgerEntry(entry(amount: 50, type: type));
        expect(c.isCharge, isFalse, reason: '$type');
      }
      final adjustment = SelectableCharge.fromLedgerEntry(
        entry(amount: 15, type: LedgerEntryType.adjustment),
      );
      expect(adjustment.isCharge, isTrue);
    });

    test('a positive refund raises the balance but real rent fills the invoice',
        () {
      LedgerEntry row(String id, double amount, LedgerEntryType type, int day,
              String description) =>
          LedgerEntry(
            id: id,
            tenantId: 't1',
            facilityId: 'f1',
            type: type,
            amount: amount,
            description: description,
            entryDate: DateTime(2026, 8, day),
            status: LedgerEntryStatus.posted,
            createdAt: DateTime(2026, 8, day),
            createdBy: 'owner',
          );
      final rows = [
        row('aug', 130, LedgerEntryType.rentCharge, 1, 'Rent - August'),
        row('pay', -180, LedgerEntryType.payment, 2, 'Check'),
        row('sep', 130, LedgerEntryType.rentCharge, 28, 'Rent - September'),
        row('ref', 50, LedgerEntryType.refund, 29, 'Refund of overpayment'),
      ];
      final balance = rows.fold<double>(0, (sum, e) => sum + e.amount);
      expect(balance, 130);
      final lines = openChargesForInvoice(
        charges: rows.map(SelectableCharge.fromLedgerEntry),
        idsOnLiveInvoices: const {},
        ledgerBalance: balance,
        liveInvoiceBalance: 0,
      );
      expect(lines.map((l) => l.id), ['sep']);
      expect(lines.single.amount, 130);
      expect(lines.single.isPartial, isFalse);
    });

    test('reads allocatedAmount from the entry metadata', () {
      final c = SelectableCharge.fromLedgerEntry(
        entry(amount: 130, metadata: {'allocatedAmount': 50}),
      );
      expect(c.allocatedAmount, 50.0);
    });
  });

  group('card disputes', () {
    // Invented rows: a tenant at a fictional facility, $130 rent a month.
    LedgerEntry row(
      String id,
      double amount,
      LedgerEntryType type,
      DateTime on, {
      String? storedType,
      Map<String, dynamic>? metadata,
      LedgerEntryStatus status = LedgerEntryStatus.posted,
    }) =>
        LedgerEntry(
          id: id,
          tenantId: 't1',
          facilityId: 'f1',
          type: type,
          amount: amount,
          description: id,
          entryDate: on,
          status: status,
          metadata: metadata,
          createdAt: on,
          createdBy: 'owner',
          storedType: storedType,
        );
    LedgerEntry dispute({LedgerEntryStatus status = LedgerEntryStatus.posted}) => row(
          'dispute_du_test1',
          130,
          LedgerEntryType.otherCharge,
          DateTime(2026, 9, 20),
          storedType: disputeLedgerType,
          metadata: {'disputeId': 'du_test1'},
          status: status,
        );
    LedgerEntry reversal() => row(
          'dispute_reversal_du_test1',
          -130,
          LedgerEntryType.otherCharge,
          DateTime(2026, 9, 28),
          storedType: disputeReversalLedgerType,
          metadata: {'disputeId': 'du_test1'},
        );
    LedgerEntry disputePayment() => row(
          'hand_payment',
          -130,
          LedgerEntryType.payment,
          DateTime(2026, 9, 25),
          metadata: {'disputeId': 'du_test1'},
        );
    final paidRent = [
      row('rent-aug', 130, LedgerEntryType.rentCharge, DateTime(2026, 8, 1)),
      row('pay-aug', -130, LedgerEntryType.payment, DateTime(2026, 8, 2)),
      row('rent-sep', 130, LedgerEntryType.rentCharge, DateTime(2026, 9, 1)),
      row('pay-sep', -130, LedgerEntryType.payment, DateTime(2026, 9, 2)),
    ];
    double sum(List<LedgerEntry> rows) => rows
        .where((e) => e.status == LedgerEntryStatus.posted)
        .fold<double>(0, (t, e) => t + e.amount);

    test('a dispute row read from the ledger is a card dispute', () {
      final c = SelectableCharge.fromLedgerEntry(dispute());
      expect(c.isCardDispute, isTrue);
      expect(c.isCharge, isTrue);
      expect(
        selectableChargeIds(charges: [c], idsOnLiveInvoices: const {}),
        isEmpty,
      );
    });

    test('rent paid and a dispute open: nothing to invoice, not paid rent', () {
      // Before: the dispute was left off the invoice but its $130 still
      // counted as owed, so September's paid rent was billed again.
      final rows = [...paidRent, dispute()];
      final lines = openChargesForInvoice(
        charges: rows.map(SelectableCharge.fromLedgerEntry),
        idsOnLiveInvoices: const {},
        ledgerBalance: sum(rows),
        liveInvoiceBalance: 0,
        cardDisputeBalance: cardDisputeShareOfBalance(rows),
      );
      expect(lines, isEmpty);
      expect(
        nothingToInvoiceMessage(
          ledgerBalance: sum(rows),
          liveInvoiceBalance: 0,
          cardDisputeBalance: cardDisputeShareOfBalance(rows),
        ),
        contains('card dispute'),
      );
    });

    test('unpaid rent beside an open dispute bills only the rent', () {
      final rows = [
        ...paidRent,
        dispute(),
        row('rent-oct', 130, LedgerEntryType.rentCharge, DateTime(2026, 10, 1)),
      ];
      final lines = openChargesForInvoice(
        charges: rows.map(SelectableCharge.fromLedgerEntry),
        idsOnLiveInvoices: const {},
        ledgerBalance: sum(rows),
        liveInvoiceBalance: 0,
        cardDisputeBalance: cardDisputeShareOfBalance(rows),
      );
      expect(_idsAndAmounts(lines), [('rent-oct', 130.0)]);
    });

    test('the dispute share of the balance', () {
      expect(cardDisputeShareOfBalance(paidRent), 0);
      expect(cardDisputeShareOfBalance([...paidRent, dispute()]), 130);
      // Collected by hand: nothing out.
      expect(cardDisputeShareOfBalance([dispute(), disputePayment()]), 0);
      // Collected by hand, then won: the tenant's credit counts like any
      // other credit, so it is no part of the dispute share.
      expect(
        cardDisputeShareOfBalance([dispute(), disputePayment(), reversal()]),
        0,
      );
      // Staff voided the dispute row and the reversal stands: that reversal
      // is not money anyone paid, so it must not shrink what rent is billed.
      expect(
        cardDisputeShareOfBalance(
            [dispute(status: LedgerEntryStatus.voided), reversal()]),
        -130,
      );
      final rows = [
        ...paidRent,
        dispute(status: LedgerEntryStatus.voided),
        reversal(),
        row('rent-oct', 130, LedgerEntryType.rentCharge, DateTime(2026, 10, 1)),
      ];
      final lines = openChargesForInvoice(
        charges: rows.map(SelectableCharge.fromLedgerEntry),
        idsOnLiveInvoices: const {},
        ledgerBalance: sum(rows),
        liveInvoiceBalance: 0,
        cardDisputeBalance: cardDisputeShareOfBalance(rows),
      );
      expect(_idsAndAmounts(lines), [('rent-oct', 130.0)]);
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
