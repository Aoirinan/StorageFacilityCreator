import 'package:sfcapp/models/tenant_model.dart';

/// One month's square in the tenant page's Payment History grid.
///
/// [paid], [late] and [movedOut] can also be set by hand: they are the values
/// stored in `monthStatusOverrides` ([storedValue]). [beforeMoveIn] and
/// [notRecorded] are only ever worked out.
enum PaymentMonthStatus {
  paid('paid'),
  late('late'),
  movedOut('moved_out'),

  /// The month ends before the tenant moved in: nothing was owed.
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
/// tenant record was made when no move-in date was saved.
DateTime tenancyStart(TenantModel tenant) => tenant.moveInDate ?? tenant.createdAt;

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

/// [paymentMonthStatus] for [tenant].
PaymentMonthStatus tenantPaymentMonthStatus(
  TenantModel tenant,
  DateTime month, {
  required double balance,
  required DateTime today,
}) =>
    paymentMonthStatus(
      month: month,
      overrides: tenant.monthStatusOverrides,
      tenancyStart: tenancyStart(tenant),
      paidThrough: tenant.paidThrough,
      balance: balance,
      today: today,
    );

/// The 12 months the grid shows, oldest first, ending with [today]'s month.
List<DateTime> paymentHistoryMonths(DateTime today) => List<DateTime>.generate(
      12,
      (i) => DateTime(today.year, today.month - (11 - i), 1),
    );
