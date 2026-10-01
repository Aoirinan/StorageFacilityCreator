import 'package:flutter_test/flutter_test.dart';
import 'package:sfcapp/models/invoice_model.dart';
import 'package:sfcapp/utils/invoice_summary.dart';

/// Mid-morning on the last day of September.
final _now = DateTime(2026, 9, 30, 10, 15);

var _seq = 0;

InvoiceModel _invoice(
  InvoiceStatus status, {
  required DateTime due,
  double total = 100,
  double? balance,
}) {
  _seq++;
  return InvoiceModel(
    id: 'inv$_seq',
    tenantId: 'tenant$_seq',
    facilityId: 'facility-a',
    invoiceNumber: 'INV-$_seq',
    status: status,
    issueDate: due.subtract(const Duration(days: 14)),
    dueDate: due,
    subtotal: total,
    total: total,
    balance: balance ?? total,
    lineItems: const [],
    ledgerEntryIds: const [],
    paymentIds: const [],
    createdAt: due.subtract(const Duration(days: 14)),
    createdBy: 'owner',
  );
}

final _lastWeek = DateTime(2026, 9, 23);
final _nextWeek = DateTime(2026, 10, 7);

int _chip(List<InvoiceModel> invoices, InvoiceStatus? filter) => invoices
    .where((i) => invoiceMatchesStatusFilter(i, filter, now: _now))
    .length;

void main() {
  test('overdue days read singular for one day', () {
    expect(InvoiceModel.overdueDaysText(1), '1 day overdue');
    expect(InvoiceModel.overdueDaysText(3), '3 days overdue');
  });

  group('isOverdueAt', () {
    test('a draft is never overdue, however late its due date', () {
      final draft = _invoice(InvoiceStatus.draft, due: DateTime(2026, 6, 1));
      expect(draft.isOverdueAt(_now), isFalse);
      expect(draft.daysOverdueAt(_now), 0);
    });

    test('a sent invoice past its due date with money owed is overdue', () {
      final sent = _invoice(InvoiceStatus.sent, due: _lastWeek);
      expect(sent.isOverdueAt(_now), isTrue);
      expect(sent.daysOverdueAt(_now), 7);
    });

    test('due today is not overdue until tomorrow, whatever the time', () {
      final dueThisMorning =
          _invoice(InvoiceStatus.sent, due: DateTime(2026, 9, 30));
      final dueTonight =
          _invoice(InvoiceStatus.sent, due: DateTime(2026, 9, 30, 23, 59));
      expect(dueThisMorning.isOverdueAt(_now), isFalse);
      expect(dueTonight.isOverdueAt(_now), isFalse);
      expect(dueThisMorning.isOverdueAt(DateTime(2026, 10, 1, 0, 1)), isTrue);
    });

    test('days overdue counts calendar days', () {
      final lateYesterday =
          _invoice(InvoiceStatus.sent, due: DateTime(2026, 9, 28, 23, 59));
      expect(lateYesterday.daysOverdueAt(DateTime(2026, 9, 30, 0, 5)), 2);
      // Across a daylight-saving change the days are still whole.
      final beforeClocksChange =
          _invoice(InvoiceStatus.sent, due: DateTime(2026, 10, 31));
      expect(beforeClocksChange.daysOverdueAt(DateTime(2026, 11, 2, 9)), 2);
    });

    test('paid, voided and fully settled invoices are not overdue', () {
      expect(
          _invoice(InvoiceStatus.paid, due: _lastWeek, balance: 0)
              .isOverdueAt(_now),
          isFalse);
      expect(_invoice(InvoiceStatus.voided, due: _lastWeek).isOverdueAt(_now),
          isFalse);
      expect(
          _invoice(InvoiceStatus.sent, due: _lastWeek, balance: 0)
              .isOverdueAt(_now),
          isFalse);
    });

    test('a partly paid sent invoice past due is overdue', () {
      expect(
          _invoice(InvoiceStatus.sent, due: _lastWeek, total: 100, balance: 40)
              .isOverdueAt(_now),
          isTrue);
    });

    test('the older stored overdue status still needs a balance and a past '
        'due date', () {
      expect(_invoice(InvoiceStatus.overdue, due: _lastWeek).isOverdueAt(_now),
          isTrue);
      expect(
          _invoice(InvoiceStatus.overdue, due: _lastWeek, balance: 0)
              .isOverdueAt(_now),
          isFalse);
      expect(_invoice(InvoiceStatus.overdue, due: _nextWeek).isOverdueAt(_now),
          isFalse);
    });
  });

  group('InvoiceSummary', () {
    test('two drafts: nothing overdue, their balances unpaid and labelled as '
        'drafts', () {
      // The facility this was reported on: two drafts, past due, and the old
      // card read "Overdue 5" from the tenants late on rent.
      final invoices = [
        _invoice(InvoiceStatus.draft, due: _lastWeek, total: 750),
        _invoice(InvoiceStatus.draft, due: _lastWeek, total: 500),
      ];
      final s = InvoiceSummary.of(invoices, now: _now);
      expect(s.count, 2);
      expect(s.paid, 0);
      expect(s.overdue, 0);
      expect(s.unpaidAmount, 1250);
      expect(s.unpaidDrafts, 2);
    });

    test('each status counts where it belongs', () {
      final invoices = [
        _invoice(InvoiceStatus.draft, due: _lastWeek, total: 50),
        _invoice(InvoiceStatus.sent, due: _lastWeek, total: 100),
        _invoice(InvoiceStatus.sent, due: _nextWeek, total: 200),
        _invoice(InvoiceStatus.sent, due: _lastWeek, total: 300, balance: 120),
        _invoice(InvoiceStatus.paid, due: _lastWeek, total: 400, balance: 0),
        _invoice(InvoiceStatus.voided, due: _lastWeek, total: 800),
      ];
      final s = InvoiceSummary.of(invoices, now: _now);
      // Voided is not an invoice anyone owes.
      expect(s.count, 5);
      expect(s.paid, 1);
      // The sent one past due and the partly paid one past due.
      expect(s.overdue, 2);
      // Draft 50 + sent 100 + sent 200 + what is left on the partly paid 120.
      expect(s.unpaidAmount, 470);
      expect(s.unpaidDrafts, 1);
    });

    test('a paid invoice with a stray balance is not unpaid', () {
      final s = InvoiceSummary.of(
        [_invoice(InvoiceStatus.paid, due: _lastWeek, total: 90, balance: 90)],
        now: _now,
      );
      expect(s.paid, 1);
      expect(s.unpaidAmount, 0);
    });

    test('the unpaid sum is exact to the cent', () {
      final s = InvoiceSummary.of([
        _invoice(InvoiceStatus.sent, due: _nextWeek, total: 0.1),
        _invoice(InvoiceStatus.sent, due: _nextWeek, total: 0.2),
      ], now: _now);
      expect(s.unpaidAmount, 0.3);
    });

    test('no invoices is all zeros', () {
      final s = InvoiceSummary.of(const [], now: _now);
      expect(s.count, 0);
      expect(s.overdue, 0);
      expect(s.unpaidAmount, 0);
      expect(s.unpaidDrafts, 0);
    });
  });

  group('the cards agree with the chips', () {
    final invoices = [
      _invoice(InvoiceStatus.draft, due: _lastWeek),
      _invoice(InvoiceStatus.draft, due: _nextWeek),
      _invoice(InvoiceStatus.sent, due: _lastWeek),
      _invoice(InvoiceStatus.sent, due: _nextWeek),
      _invoice(InvoiceStatus.sent, due: _lastWeek, balance: 30),
      _invoice(InvoiceStatus.overdue, due: _lastWeek),
      _invoice(InvoiceStatus.paid, due: _lastWeek, balance: 0),
      _invoice(InvoiceStatus.paid, due: _nextWeek, balance: 0),
      _invoice(InvoiceStatus.voided, due: _lastWeek),
    ];
    final s = InvoiceSummary.of(invoices, now: _now);

    test('All lists what Invoices counts, voided left out', () {
      expect(_chip(invoices, null), s.count);
      expect(s.count, 8);
    });

    test('Paid lists what Paid counts', () {
      expect(_chip(invoices, InvoiceStatus.paid), s.paid);
      expect(s.paid, 2);
    });

    test('Overdue lists what Overdue counts, drafts left out', () {
      expect(_chip(invoices, InvoiceStatus.overdue), s.overdue);
      expect(s.overdue, 3);
    });

    test('the other chips filter by stored status', () {
      expect(_chip(invoices, InvoiceStatus.draft), 2);
      expect(_chip(invoices, InvoiceStatus.sent), 3);
      expect(_chip(invoices, InvoiceStatus.voided), 1);
    });
  });
}
