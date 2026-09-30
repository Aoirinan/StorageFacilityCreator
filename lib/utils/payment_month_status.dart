import 'package:sfcapp/models/ledger_entry_model.dart';
import 'package:sfcapp/models/tenant_model.dart';
import 'package:sfcapp/utils/past_history_math.dart' show isPastHistoryEntry;

/// One month's square in the tenant page's Payment History grid.
///
/// [paid], [late] and [movedOut] can also be set by hand: they are the values
/// stored in `monthStatusOverrides` ([storedValue]). [beforeMoveIn] and
/// [notRecorded] are only ever worked out.
enum PaymentMonthStatus {
  paid('paid'),
  late('late'),
  movedOut('moved_out'),

  /// The month ends before the tenant moved in (and before the first
  /// payment entered with Enter past history): nothing was owed.
  beforeMoveIn(null),

  /// Not covered by paidThrough, and nothing shows it is late: a month still
  /// to come, the current month before anything is owed, or an owner's
  /// history that was never entered (a tenant brought over from a paper
  /// ledger with a $0 balance).
  notRecorded(null);

  const PaymentMonthStatus(this.storedValue);

  /// The `monthStatusOverrides` value for this status, null for the ones
  /// that cannot be stored.
  final String? storedValue;

  /// The status a stored override value names, null for a blank or unknown
  /// value (which then counts as no override).
  static PaymentMonthStatus? fromStored(String? value) {
    for (final s in values) {
      if (s.storedValue != null && s.storedValue == value) return s;
    }
    return null;
  }
}

/// The `monthStatusOverrides` key for [month]: "2026-09".
String paymentMonthKey(DateTime month) =>
    '${month.year}-${month.month.toString().padLeft(2, '0')}';

/// The day the tenant's history starts: their move-in date, or the day the
/// tenant record was made when no move-in date was saved; or the day of
/// [firstPastHistoryPayment] when that is earlier.
///
/// Enter past history only saves its move-in date on a tenant that has none,
/// so a tenant typed in with the day they were entered as move-in kept that
/// date, and every month of the checks entered before it showed as "Before
/// move-in". A check the owner says came in back then means they were a
/// tenant then.
///
/// Only a past-history payment ([firstPastHistoryPaymentDate]) moves the
/// start. Any payment used to: a renter who pays online on Sep 28 for an
/// Oct 3 move-in then had September, before they moved in, in the grid as
/// Late (or Paid).
DateTime tenancyStart(TenantModel tenant, {DateTime? firstPastHistoryPayment}) {
  final start = tenant.moveInDate ?? tenant.createdAt;
  if (firstPastHistoryPayment != null && firstPastHistoryPayment.isBefore(start)) {
    return firstPastHistoryPayment;
  }
  return start;
}

/// The date of the oldest posted payment on [entries] that was entered with
/// Enter past history (`metadata.source == 'past_history'`), null when there
/// is none. Pending and voided rows (money not received, or an entry taken
/// back with Undo) do not count, and neither does a payment taken any other
/// way: see [tenancyStart].
DateTime? firstPastHistoryPaymentDate(Iterable<LedgerEntry> entries) {
  DateTime? first;
  for (final e in entries) {
    if (e.type != LedgerEntryType.payment || e.status != LedgerEntryStatus.posted) continue;
    if (!isPastHistoryEntry(e)) continue;
    if (first == null || e.entryDate.isBefore(first)) first = e.entryDate;
  }
  return first;
}

/// The status of [month] (any day in it) for the Payment History grid.
///
/// In order:
/// 1. a stored override ([overrides], set by clicking the month) wins;
/// 2. a month before the month of [tenancyStart] is [PaymentMonthStatus.beforeMoveIn];
/// 3. a month up to and including the month of [paidThrough] is paid;
/// 4. a month that fell due (its 1st) before [today] is late only while the
///    ledger [balance] is above zero;
/// 5. anything else is [PaymentMonthStatus.notRecorded].
///
/// It used to be "paid up to paidThrough, late otherwise", so a tenant with
/// no paidThrough, or months before they moved in, showed a full year late.
PaymentMonthStatus paymentMonthStatus({
  required DateTime month,
  required Map<String, String> overrides,
  required DateTime? tenancyStart,
  required DateTime? paidThrough,
  required double balance,
  required DateTime today,
}) {
  final override = PaymentMonthStatus.fromStored(overrides[paymentMonthKey(month)]);
  if (override != null) return override;

  final monthStart = DateTime(month.year, month.month);
  if (tenancyStart != null &&
      monthStart.isBefore(DateTime(tenancyStart.year, tenancyStart.month))) {
    return PaymentMonthStatus.beforeMoveIn;
  }
  if (paidThrough != null &&
      !monthStart.isAfter(DateTime(paidThrough.year, paidThrough.month))) {
    return PaymentMonthStatus.paid;
  }
  final todayStart = DateTime(today.year, today.month, today.day);
  if (monthStart.isBefore(todayStart) && balance > 0) {
    return PaymentMonthStatus.late;
  }
  return PaymentMonthStatus.notRecorded;
}

/// [paymentMonthStatus] for [tenant]. [firstPastHistoryPayment] is
/// [firstPastHistoryPaymentDate] of their ledger (see [tenancyStart]).
PaymentMonthStatus tenantPaymentMonthStatus(
  TenantModel tenant,
  DateTime month, {
  required double balance,
  required DateTime today,
  DateTime? firstPastHistoryPayment,
}) =>
    paymentMonthStatus(
      month: month,
      overrides: tenant.monthStatusOverrides,
      tenancyStart: tenancyStart(tenant, firstPastHistoryPayment: firstPastHistoryPayment),
      paidThrough: tenant.paidThrough,
      balance: balance,
      today: today,
    );

/// The 12 months the grid shows, oldest first, ending with [today]'s month.
List<DateTime> paymentHistoryMonths(DateTime today) => List<DateTime>.generate(
      12,
      (i) => DateTime(today.year, today.month - (11 - i), 1),
    );
