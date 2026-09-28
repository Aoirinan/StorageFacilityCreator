import 'package:sfcapp/models/tenant_model.dart';

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

/// The paidThrough value for "paid through [month] [year]": the last day of
/// that month, at local midnight.
///
/// "Paid through July" means July is paid, so the value is July 31, the same
/// shape PaymentService.advancePaidThrough writes after a payment. The Set
/// Paid Through dialog used to store the 1st, which counted the tenant a
/// month behind: late from August 1 with no grace, and about 30 days later in
/// the delinquency job than a tenant who paid the same month.
DateTime paidThroughMonthEnd(int year, int month) => DateTime(year, month + 1, 0);

/// "July 2026".
String paidThroughMonthLabel(int year, int month) =>
    '${_monthNames[month - 1]} $year';

/// "Paid through the end of July 2026".
String paidThroughEndLabel(int year, int month) =>
    'Paid through the end of ${paidThroughMonthLabel(year, month)}';

/// The calendar day of [d], without its time. paidThrough values arrive at
/// local midnight or, from the server, at another hour of the same day.
DateTime _day(DateTime d) => DateTime(d.year, d.month, d.day);

/// Who a bulk "Paid through" writes, and who it leaves alone.
class PaidThroughBulkPlan {
  /// The value written: the last day of the chosen month.
  final DateTime paidThrough;

  /// Tenants to mark paid through [paidThrough].
  final List<TenantModel> toUpdate;

  /// Tenants already paid through a later date. Left as they are: marking
  /// them would take back months they have paid for.
  final List<TenantModel> alreadyLater;

  const PaidThroughBulkPlan({
    required this.paidThrough,
    required this.toUpdate,
    required this.alreadyLater,
  });
}

/// Splits [tenants] for marking them paid through the end of [month] [year].
/// A tenant whose paidThrough is on the same day is written again (a no-op
/// for the date); only a later one is skipped.
PaidThroughBulkPlan planPaidThroughBulk(
  List<TenantModel> tenants, {
  required int year,
  required int month,
}) {
  final target = paidThroughMonthEnd(year, month);
  final toUpdate = <TenantModel>[];
  final later = <TenantModel>[];
  for (final t in tenants) {
    final current = t.paidThrough;
    if (current != null && _day(current).isAfter(target)) {
      later.add(t);
    } else {
      toUpdate.add(t);
    }
  }
  return PaidThroughBulkPlan(
    paidThrough: target,
    toUpdate: toUpdate,
    alreadyLater: later,
  );
}
