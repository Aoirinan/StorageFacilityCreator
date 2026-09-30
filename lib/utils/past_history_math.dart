import 'package:sfcapp/models/ledger_entry_model.dart';
import 'package:sfcapp/models/payment_model.dart';

/// The Enter past history screen's arithmetic: which months to propose,
/// and the balance and paid-through date the owner will get. The
/// recordTenantPastHistory callable (functions-automation/src/
/// tenantPastHistory.ts) decides for real with the same rules; this is the
/// preview the owner confirms before saving.

const _monthNames = [
  'January',
  'February',
  'March',
  'April',
  'May',
  'June',
  'July',
  'August',
  'September',
  'October',
  'November',
  'December',
];

String historyMonthLabel(int year, int month) => '${_monthNames[month - 1]} $year';

int _monthKey(int year, int month) => year * 12 + (month - 1);

int _daysInMonth(int year, int month) => DateTime.utc(year, month + 1, 0).day;

/// One month of rent in the proposal. The owner can untick it (a free
/// month) or change its amount.
class ProposedHistoryCharge {
  ProposedHistoryCharge({
    required this.year,
    required this.month,
    required this.day,
    required this.amount,
    this.included = true,
  });

  final int year;
  final int month;

  /// Day of the month the charge is dated: the move-in day for the move-in
  /// month, the 1st after that.
  final int day;
  double amount;
  bool included;

  String get label => historyMonthLabel(year, month);

  Map<String, Object> toPayload() => {
        'year': year,
        'month': month,
        'day': day,
        'amount': double.parse(amount.toStringAsFixed(2)),
      };
}

/// A payment received, as the owner types it in.
class HistoryPaymentInput {
  HistoryPaymentInput({
    required this.date,
    required this.amount,
    this.method = PaymentMethod.cash,
    this.reference,
    this.note,
    this.monthOnly = false,
  });

  /// The calendar day received (time of day ignored).
  DateTime date;

  /// Only the month is known ("September \$1000"): saved as the 1st, and
  /// the ledger line names the month.
  bool monthOnly;
  double amount;
  PaymentMethod method;
  String? reference;
  String? note;

  String get isoDate =>
      '${date.year.toString().padLeft(4, '0')}-${date.month.toString().padLeft(2, '0')}-${(monthOnly ? 1 : date.day).toString().padLeft(2, '0')}';

  /// The day it counts from: the 1st for a month-only date.
  DateTime get effectiveDate => monthOnly ? DateTime(date.year, date.month, 1) : DateTime(date.year, date.month, date.day);

  Map<String, Object?> toPayload() => {
        'date': isoDate,
        if (monthOnly) 'monthOnly': true,
        'amount': double.parse(amount.toStringAsFixed(2)),
        'method': method.name,
        if (reference != null && reference!.trim().isNotEmpty) 'reference': reference!.trim(),
        if (note != null && note!.trim().isNotEmpty) 'note': note!.trim(),
      };
}

/// The billing month a posted rent charge is for, or null when [entry] is
/// not one. Same rule as the server's rentChargeMonthOf: the recurring
/// metadata when present, else the UTC month of the entry's date (moved
/// half a day so a local-midnight date is not read as the day before).
({int year, int month})? rentChargeMonthOfEntry(LedgerEntry entry) {
  if (entry.status != LedgerEntryStatus.posted) return null;
  if (entry.type != LedgerEntryType.rentCharge) return null;
  final meta = entry.metadata;
  if (meta != null &&
      meta['chargeType'] == 'monthlyRent' &&
      meta['month'] is int &&
      meta['year'] is int) {
    return (year: meta['year'] as int, month: meta['month'] as int);
  }
  final shifted = entry.entryDate.toUtc().add(const Duration(hours: 12));
  return (year: shifted.year, month: shifted.month);
}

/// What the proposal covers and why it stops where it does.
class HistoryChargeProposal {
  const HistoryChargeProposal({
    required this.charges,
    this.stoppedBefore,
  });

  final List<ProposedHistoryCharge> charges;

  /// The first month on or after move-in that already has a rent charge, if
  /// the proposal stopped there.
  final ({int year, int month})? stoppedBefore;
}

/// One charge per month at [monthlyRate], from the move-in month through
/// the month before the first one that already has a rent charge, or
/// through [today]'s month when none does. The move-in month is dated the
/// move-in day, later months the 1st.
HistoryChargeProposal proposeHistoryCharges({
  required DateTime moveIn,
  required double monthlyRate,
  required List<LedgerEntry> existing,
  required DateTime today,
}) {
  final startKey = _monthKey(moveIn.year, moveIn.month);
  final todayKey = _monthKey(today.year, today.month);

  int? firstChargedKey;
  ({int year, int month})? firstCharged;
  for (final entry in existing) {
    final m = rentChargeMonthOfEntry(entry);
    if (m == null) continue;
    final key = _monthKey(m.year, m.month);
    if (key < startKey) continue;
    if (firstChargedKey == null || key < firstChargedKey) {
      firstChargedKey = key;
      firstCharged = m;
    }
  }

  final endKey = firstChargedKey != null ? firstChargedKey - 1 : todayKey;
  final charges = <ProposedHistoryCharge>[];
  for (var key = startKey; key <= endKey && key <= todayKey; key++) {
    final year = key ~/ 12;
    final month = key % 12 + 1;
    charges.add(ProposedHistoryCharge(
      year: year,
      month: month,
      day: key == startKey ? moveIn.day.clamp(1, _daysInMonth(year, month)) : 1,
      amount: monthlyRate,
    ));
  }
  return HistoryChargeProposal(charges: charges, stoppedBefore: firstCharged);
}

/// The amounts the owner typed into [charges] that are not [monthlyRate],
/// each once in the order they appear, for the warning under the months. A
/// person renting two units was entered at their combined rent on a record
/// whose rate was one unit's, and nothing said the months were double the
/// rate. Only ticked months with an amount count, and only when there is a
/// rate to compare with. The move-in month is left out when it is dated
/// after the 1st and below the rate: a prorated first month is the
/// difference the form invites.
List<double> historyAmountsOffRate({
  required List<ProposedHistoryCharge> charges,
  required double monthlyRate,
}) {
  if (monthlyRate <= 0) return const [];
  final rate = _cents(monthlyRate);
  final off = <double>[];
  for (var i = 0; i < charges.length; i++) {
    final c = charges[i];
    if (!c.included || c.amount <= 0) continue;
    final amount = _cents(c.amount);
    if (amount == rate || off.contains(amount)) continue;
    if (i == 0 && c.day != 1 && amount < rate) continue;
    off.add(amount);
  }
  return off;
}

/// What to do with paidThrough when the recomputed date differs from the
/// tenant's. Same names as the server's paidThroughChoice.
enum PaidThroughChoice {
  /// Use the date the ledger works out to after the save, even if earlier.
  computed,

  /// Only move it later; keep a later date already set.
  keepLater,
}

/// What the owner will see once this history is saved.
class HistoryPreview {
  const HistoryPreview({
    required this.totalCharges,
    required this.totalPayments,
    required this.balance,
    required this.computedPaidThrough,
    required this.resultingPaidThrough,
    required this.paidThroughChanges,
    required this.credit,
    required this.firstUnpaidMonth,
    this.paidThroughNow,
    this.paidThroughWarning,
    this.existingCharges = 0,
    this.existingChargeTotal = 0,
    this.existingPayments = 0,
    this.existingPaymentTotal = 0,
    this.voidedCount = 0,
    this.voidsPayment = false,
    this.choice = PaidThroughChoice.keepLater,
    this.prepaidMonths = 0,
    this.invoiceIds = const [],
  });

  /// Posted entries already on the ledger that stay (not ticked to void),
  /// and so count in [balance].
  final int existingCharges;
  final double existingChargeTotal;
  final int existingPayments;
  final double existingPaymentTotal;

  /// Existing entries this save voids, and whether any is a payment.
  final int voidedCount;
  final bool voidsPayment;

  /// This entry's charges and payments.
  final double totalCharges;
  final double totalPayments;

  /// The Ledger screen's Current Balance after saving (sum of posted entries).
  final double balance;

  /// The tenant's paid-through date now.
  final DateTime? paidThroughNow;

  /// End of the last rent month paid once saved (a calendar date), or null.
  final DateTime? computedPaidThrough;

  /// What the tenant's paid-through date will be after saving.
  final DateTime? resultingPaidThrough;
  final bool paidThroughChanges;

  /// The choice the preview used (the owner's, or the default).
  final PaidThroughChoice choice;

  /// True when saving recomputes to a date earlier than [paidThroughNow],
  /// so the owner chooses between the two.
  bool get recomputedIsEarlier =>
      paidThroughNow != null &&
      (computedPaidThrough == null ||
          _dateOnly(computedPaidThrough!).isBefore(_dateOnly(paidThroughNow!).subtract(const Duration(days: 1))));

  /// Money paid beyond the rent months it covers: part of
  /// [firstUnpaidMonth]'s rent, or less than a month ahead.
  final double credit;
  final ({int year, int month})? firstUnpaidMonth;

  /// Whole months past the last charged month the credit pays for.
  final int prepaidMonths;

  /// Invoices the entries being voided are on (metadata.invoiceId).
  final List<String> invoiceIds;

  /// Set when the tenant already has a later paid-through date, which is kept.
  final String? paidThroughWarning;
}

double _cents(double v) => double.parse(v.toStringAsFixed(2));

DateTime _dateOnly(DateTime d) => DateTime(d.year, d.month, d.day);

String _formatDay(DateTime d) => '${d.month}/${d.day}/${d.year}';

/// The default [PaidThroughChoice]: recompute when the save voids a payment
/// (the payments that pushed paidThrough forward are going), otherwise only
/// ever move it later.
PaidThroughChoice defaultPaidThroughChoice({required bool voidsPayment}) =>
    voidsPayment ? PaidThroughChoice.computed : PaidThroughChoice.keepLater;

/// Balance and paid-through for the tenant's ledger as it will stand after
/// the save: [existing] less the entries in [voiding], plus the ticked
/// [charges] and the [payments]. Same rules as the server's
/// computeHistoryOutcome:
///
/// * only rent decides paid-through: all money paid is applied to the rent
///   months in month order; fees count in the balance only;
/// * an unticked (free) month right after a paid month counts as paid;
/// * months past the last charged month are bought only with real credit
///   (the whole balance below zero, fees and deposits included), in whole
///   months at [monthlyRate]; less than a month is a credit;
/// * card-dispute rows ([LedgerEntry.isCardDispute]) count in the balance
///   only: a reversal, or a payment staff took for a lost dispute, settles
///   the dispute, and in the pool it bought a rent month nobody paid for.
HistoryPreview computeHistoryPreview({
  required List<LedgerEntry> existing,
  required List<ProposedHistoryCharge> charges,
  required List<HistoryPaymentInput> payments,
  required DateTime? existingPaidThrough,
  Set<String> voiding = const {},
  double monthlyRate = 0,
  PaidThroughChoice? choice,
}) {
  final rentByMonth = <int, double>{};
  var pool = 0.0;
  var balance = 0.0;
  var disputed = 0.0;
  var existingCharges = 0;
  var existingChargeTotal = 0.0;
  var existingPayments = 0;
  var existingPaymentTotal = 0.0;
  var voidedCount = 0;
  var voidsPayment = false;
  final invoiceIds = <String>{};

  for (final e in existing) {
    if (e.status != LedgerEntryStatus.posted || e.amount == 0) continue;
    if (voiding.contains(e.id)) {
      voidedCount++;
      if (e.amount < 0) voidsPayment = true;
      final inv = e.metadata?['invoiceId'];
      if (inv is String && inv.isNotEmpty) invoiceIds.add(inv);
      continue;
    }
    balance += e.amount;
    if (e.amount < 0) {
      existingPayments++;
      existingPaymentTotal -= e.amount;
      if (e.isCardDispute) {
        disputed += e.amount;
      } else {
        pool += -e.amount;
      }
      continue;
    }
    existingCharges++;
    existingChargeTotal += e.amount;
    if (e.isCardDispute) {
      disputed += e.amount;
      continue;
    }
    final m = rentChargeMonthOfEntry(e);
    if (m != null) {
      final key = _monthKey(m.year, m.month);
      rentByMonth[key] = (rentByMonth[key] ?? 0) + e.amount;
    }
  }

  var totalCharges = 0.0;
  final free = <int>{};
  for (final c in charges) {
    if (!c.included) {
      free.add(_monthKey(c.year, c.month));
      continue;
    }
    if (c.amount <= 0) continue;
    totalCharges += c.amount;
    balance += c.amount;
    final key = _monthKey(c.year, c.month);
    rentByMonth[key] = (rentByMonth[key] ?? 0) + c.amount;
  }

  var totalPayments = 0.0;
  for (final p in payments.where((p) => p.amount > 0)) {
    totalPayments += p.amount;
    balance -= p.amount;
    pool += p.amount;
  }

  pool = _cents(pool);
  final months = rentByMonth.keys.toList()..sort();
  int? lastCovered;
  int? firstUnpaid;
  for (final key in months) {
    final need = _cents(rentByMonth[key]!);
    if (pool + 0.005 >= need) {
      pool = _cents(pool - need);
      lastCovered = key;
      continue;
    }
    firstUnpaid = key;
    break;
  }
  while (lastCovered != null &&
      free.contains(lastCovered + 1) &&
      !rentByMonth.containsKey(lastCovered + 1) &&
      (firstUnpaid == null || lastCovered + 1 < firstUnpaid)) {
    lastCovered += 1;
  }
  // Months past the last charged one are bought only with real credit: the
  // whole balance below zero, fees and deposits included (dispute rows
  // aside), so money that paid a deposit or a fee does not buy future rent.
  var prepaidMonths = 0;
  if (firstUnpaid == null) {
    final rentBalance = balance - disputed;
    final credit = rentBalance < 0 ? _cents(-rentBalance) : 0.0;
    if (lastCovered != null && monthlyRate > 0) {
      prepaidMonths = ((credit + 0.005) / monthlyRate).floor();
      lastCovered += prepaidMonths;
    }
    pool = _cents(credit - prepaidMonths * monthlyRate);
  }

  final computed = lastCovered == null ? null : DateTime(lastCovered ~/ 12, lastCovered % 12 + 2, 0);
  final used = choice ?? defaultPaidThroughChoice(voidsPayment: voidsPayment);

  final now = existingPaidThrough == null ? null : _dateOnly(existingPaidThrough);
  DateTime? resulting = now;
  var changes = false;
  String? warning;
  bool sameDay(DateTime? a, DateTime? b) =>
      (a == null || b == null) ? a == b : (a.difference(b).inHours / 24).round().abs() <= 1;
  if (!sameDay(now, computed)) {
    if (used == PaidThroughChoice.computed) {
      resulting = computed;
      changes = true;
    } else if (computed != null) {
      if (now == null || computed.isAfter(now)) {
        resulting = computed;
        changes = true;
      } else {
        warning = 'Paid through stays at ${_formatDay(now)}, which is later than the '
            '${_formatDay(computed)} this history works out to.';
      }
    }
  }

  return HistoryPreview(
    totalCharges: _cents(totalCharges),
    totalPayments: _cents(totalPayments),
    balance: _cents(balance),
    paidThroughNow: now,
    computedPaidThrough: computed,
    resultingPaidThrough: resulting,
    paidThroughChanges: changes,
    choice: used,
    credit: _cents(pool),
    firstUnpaidMonth: firstUnpaid == null ? null : (year: firstUnpaid ~/ 12, month: firstUnpaid % 12 + 1),
    prepaidMonths: prepaidMonths,
    paidThroughWarning: warning,
    existingCharges: existingCharges,
    existingChargeTotal: _cents(existingChargeTotal),
    existingPayments: existingPayments,
    existingPaymentTotal: _cents(existingPaymentTotal),
    voidedCount: voidedCount,
    voidsPayment: voidsPayment,
    invoiceIds: invoiceIds.toList()..sort(),
  );
}

/// Whether [entry] came from Enter past history (undone as a whole, not
/// voided one by one from a later entry).
bool isPastHistoryEntry(LedgerEntry entry) => entry.metadata?['source'] == 'past_history';

/// A payment date as the owner types it: 8/17/2026, 2026-08-17, or just the
/// month (8/2026, 2026-08, "August 2026", "Aug 2026"), which is dated the 1st.
/// Null when it cannot be read or is not a real date.
({DateTime date, bool monthOnly})? parseHistoryDateInput(String raw) {
  final text = raw.trim();
  if (text.isEmpty) return null;
  DateTime? real(int y, int m, int d) {
    if (y < 1900 || y > 2999 || m < 1 || m > 12 || d < 1 || d > _daysInMonth(y, m)) return null;
    return DateTime(y, m, d);
  }

  var m = RegExp(r'^(\d{1,2})/(\d{1,2})/(\d{4})$').firstMatch(text);
  if (m != null) {
    final d = real(int.parse(m[3]!), int.parse(m[1]!), int.parse(m[2]!));
    return d == null ? null : (date: d, monthOnly: false);
  }
  m = RegExp(r'^(\d{4})-(\d{1,2})-(\d{1,2})$').firstMatch(text);
  if (m != null) {
    final d = real(int.parse(m[1]!), int.parse(m[2]!), int.parse(m[3]!));
    return d == null ? null : (date: d, monthOnly: false);
  }
  m = RegExp(r'^(\d{1,2})/(\d{4})$').firstMatch(text);
  if (m != null) {
    final d = real(int.parse(m[2]!), int.parse(m[1]!), 1);
    return d == null ? null : (date: d, monthOnly: true);
  }
  m = RegExp(r'^(\d{4})-(\d{1,2})$').firstMatch(text);
  if (m != null) {
    final d = real(int.parse(m[1]!), int.parse(m[2]!), 1);
    return d == null ? null : (date: d, monthOnly: true);
  }
  m = RegExp(r'^([A-Za-z]+)\.?\s+(\d{4})$').firstMatch(text);
  if (m != null) {
    final word = m[1]!.toLowerCase();
    if (word.length >= 3) {
      for (var i = 0; i < _monthNames.length; i++) {
        if (_monthNames[i].toLowerCase().startsWith(word)) {
          final d = real(int.parse(m[2]!), i + 1, 1);
          return d == null ? null : (date: d, monthOnly: true);
        }
      }
    }
  }
  return null;
}

/// How a payment date reads back in the form: 8/17/2026, or 8/2026 for a
/// month-only date.
String formatHistoryDateInput(DateTime date, {bool monthOnly = false}) =>
    monthOnly ? '${date.month}/${date.year}' : '${date.month}/${date.day}/${date.year}';

/// The history entries on a tenant's ledger, newest first: the requestId
/// each was saved under and what is still posted from it. The ledger
/// screen offers "Undo this history entry" for each.
class HistoryBatchSummary {
  const HistoryBatchSummary({
    required this.requestId,
    required this.charges,
    required this.payments,
    required this.totalCharges,
    required this.totalPayments,
    required this.savedAt,
  });

  final String requestId;
  final int charges;
  final int payments;
  final double totalCharges;
  final double totalPayments;
  final DateTime savedAt;
}

List<HistoryBatchSummary> postedHistoryBatches(List<LedgerEntry> entries) {
  final byRequest = <String, List<LedgerEntry>>{};
  for (final e in entries) {
    if (e.status != LedgerEntryStatus.posted) continue;
    final meta = e.metadata;
    if (meta == null || meta['source'] != 'past_history') continue;
    final id = meta['historyRequestId'];
    if (id is! String || id.isEmpty) continue;
    byRequest.putIfAbsent(id, () => []).add(e);
  }
  final out = byRequest.entries.map((kv) {
    final list = kv.value;
    final charges = list.where((e) => e.amount > 0).toList();
    final payments = list.where((e) => e.amount < 0).toList();
    return HistoryBatchSummary(
      requestId: kv.key,
      charges: charges.length,
      payments: payments.length,
      totalCharges: _cents(charges.fold(0.0, (s, e) => s + e.amount)),
      totalPayments: _cents(payments.fold(0.0, (s, e) => s - e.amount)),
      savedAt: list.map((e) => e.createdAt).reduce((a, b) => a.isAfter(b) ? a : b),
    );
  }).toList()
    ..sort((a, b) => b.savedAt.compareTo(a.savedAt));
  return out;
}
