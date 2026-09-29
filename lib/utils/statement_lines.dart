import 'package:sfcapp/models/ledger_entry_model.dart';

/// The rows of a tenant's account statement, worked out from their ledger
/// with the ledger's own balance rule: posted entries only, signed amounts
/// summed (lib/providers/ledger_provider.dart sumPostedLedgerEntries). The
/// statement used to keep a rule of its own that subtracted every payment,
/// credit and refund whatever its stored sign and counted pending entries,
/// so a refunded tenant's printed balance disagreed with the ledger page.
///
/// The sign is whatever the writer stored, and the writers do not all agree
/// with the model's "payments and credits negative" contract: refunds are
/// written positive by the move-out flow, the portal move-out hold
/// (functions-tenant-lifecycle moveOutPortalHold.ts, since PR #39), the
/// manual entry dialog and the Stripe webhook (money handed back raises what
/// is owed), though refunds the portal hold wrote before PR #39 are still
/// stored negative; and the transfer flow writes its prorated "Transfer
/// refund" credit positive where the manual dialog writes credits negative.
/// Such an entry prints on the side its stored sign says and moves the
/// balance the way the ledger header already moves it; the fix belongs with
/// the writer, not with a second balance rule here.
///
/// Pure: no Firebase, so the ledger screen, the emailed statement and a bulk
/// print all get the same figures from the same entries.

/// One line of the transactions table.
class StatementRow {
  final DateTime date;
  final String description;

  /// The amount under Charges: the entry's amount when it raised the
  /// balance, else 0.
  final double charge;

  /// The amount under Payments: the entry's amount, made positive, when it
  /// lowered the balance, else 0.
  final double payment;

  /// The balance after this row, rounded to cents.
  final double runningBalance;

  const StatementRow({
    required this.date,
    required this.description,
    required this.charge,
    required this.payment,
    required this.runningBalance,
  });
}

class StatementLines {
  /// The balance of the posted entries dated before the start date; 0 when
  /// the statement has no start date.
  final double balanceForward;
  final List<StatementRow> rows;

  /// [balanceForward] plus every row: for all history, the ledger balance.
  final double closingBalance;

  const StatementLines({
    required this.balanceForward,
    required this.rows,
    required this.closingBalance,
  });
}

/// Whether [date] falls in the statement period: on or after [startDate]
/// and on or before the last moment of [endDate]'s calendar day. Either
/// bound null is open. The ledger screen's on-screen filter uses this too,
/// so what it shows for a period is what the statement prints.
bool inStatementPeriod(
  DateTime date, {
  DateTime? startDate,
  DateTime? endDate,
}) {
  if (startDate != null && date.isBefore(startDate)) return false;
  if (endDate != null && !date.isBefore(_dayAfter(endDate))) return false;
  return true;
}

/// Midnight after [day], by calendar so a DST change never shortens or
/// lengthens the last day of the period.
DateTime _dayAfter(DateTime day) =>
    DateTime(day.year, day.month, day.day + 1);

double _cents(double v) => double.parse(v.toStringAsFixed(2));

/// [date]'s calendar day where the statement is read, as a number that
/// orders by day: rows print by the day the owner sees in the Date column.
int _localDay(DateTime date) {
  final local = date.toLocal();
  return local.year * 10000 + local.month * 100 + local.day;
}

/// Oldest day first. On one local calendar day, entries that raise the
/// balance before entries that lower it, whatever their times, so a rent
/// charge and the check that paid it never read as a credit followed by a
/// charge; then by time, then creation order, then id so two runs print the
/// same page.
int _compareForStatement(LedgerEntry a, LedgerEntry b) {
  final byDay = _localDay(a.entryDate).compareTo(_localDay(b.entryDate));
  if (byDay != 0) return byDay;
  final aLowers = a.amount < 0;
  final bLowers = b.amount < 0;
  if (aLowers != bLowers) return aLowers ? 1 : -1;
  final byTime = a.entryDate.compareTo(b.entryDate);
  if (byTime != 0) return byTime;
  final byCreated = a.createdAt.compareTo(b.createdAt);
  if (byCreated != 0) return byCreated;
  return a.id.compareTo(b.id);
}

/// [entries] may be the tenant's whole ledger or one already cut to the
/// period; either way pending and voided entries are left out, entries
/// before [startDate] become the balance forward, entries in the period
/// become rows and entries after [endDate]'s day are dropped.
StatementLines buildStatementLines(
  List<LedgerEntry> entries, {
  DateTime? startDate,
  DateTime? endDate,
}) {
  final posted = [
    for (final e in entries)
      if (e.status == LedgerEntryStatus.posted) e,
  ]..sort(_compareForStatement);

  var balanceForward = 0.0;
  if (startDate != null) {
    for (final e in posted) {
      if (e.entryDate.isBefore(startDate)) balanceForward += e.amount;
    }
  }
  balanceForward = _cents(balanceForward);

  var running = balanceForward;
  final rows = <StatementRow>[];
  for (final e in posted) {
    if (!inStatementPeriod(e.entryDate, startDate: startDate, endDate: endDate)) {
      continue;
    }
    running = _cents(running + e.amount);
    rows.add(StatementRow(
      date: e.entryDate,
      description: e.description ?? e.typeDisplayName,
      charge: e.amount > 0 ? e.amount : 0.0,
      payment: e.amount < 0 ? -e.amount : 0.0,
      runningBalance: running,
    ));
  }

  return StatementLines(
    balanceForward: balanceForward,
    rows: rows,
    closingBalance: running,
  );
}
