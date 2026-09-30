import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:sfcapp/models/ledger_entry_model.dart';
import 'package:sfcapp/models/tenant_model.dart';
import 'package:sfcapp/providers/ledger_provider.dart';
import 'package:sfcapp/theme/app_theme.dart';
import 'package:sfcapp/utils/payment_month_status.dart';
import 'package:sfcapp/utils/received_payments.dart';

/// The Payment History block in the tenant page's Financial Summary: counts,
/// the last 12 months, each worked out by [tenantPaymentMonthStatus] from the
/// tenant and the balance of [entries], and the payments received on the
/// ledger ([receivedPayments]) with their dates and check numbers.
class PaymentHistorySummary extends StatelessWidget {
  /// How many payments are listed; View Ledger has the rest.
  static const int receivedListLimit = 12;

  final TenantModel tenant;

  /// The tenant's ledger (every status; only posted entries count towards
  /// the balance).
  final List<LedgerEntry> entries;
  final DateTime today;

  /// Called with the month clicked and the status it shows. Null while a
  /// change is being saved.
  final void Function(DateTime month, PaymentMonthStatus status)? onMonthTap;

  const PaymentHistorySummary({
    super.key,
    required this.tenant,
    required this.entries,
    required this.today,
    this.onMonthTap,
  });

  static Color statusColor(PaymentMonthStatus status) {
    switch (status) {
      case PaymentMonthStatus.paid:
        return AppTheme.success;
      case PaymentMonthStatus.late:
        return AppTheme.error;
      case PaymentMonthStatus.movedOut:
        return AppTheme.warning;
      case PaymentMonthStatus.notRecorded:
        return AppTheme.textSecondary;
      case PaymentMonthStatus.beforeMoveIn:
        return AppTheme.textTertiary;
    }
  }

  static String statusLabel(PaymentMonthStatus status) {
    switch (status) {
      case PaymentMonthStatus.paid:
        return 'Paid';
      case PaymentMonthStatus.late:
        return 'Late';
      case PaymentMonthStatus.movedOut:
        return 'Moved out';
      case PaymentMonthStatus.notRecorded:
        return 'Not recorded';
      case PaymentMonthStatus.beforeMoveIn:
        return 'Before move-in';
    }
  }

  @override
  Widget build(BuildContext context) {
    // A refund is money handed back to the tenant, not a payment they made,
    // so it is not counted here: a tenant who paid once and was refunded
    // used to show two payments made.
    final paymentCount = entries
        .where((e) =>
            e.status != LedgerEntryStatus.voided &&
            (e.type == LedgerEntryType.payment ||
                e.type == LedgerEntryType.credit))
        .length;
    final balance = sumPostedLedgerEntries(entries);
    final months = paymentHistoryMonths(today);
    // Newest first, so the last one is the first payment on the ledger.
    final received = receivedPayments(entries);
    final firstReceived = received.isEmpty ? null : received.last.receivedOn;
    final statuses = [
      for (final m in months)
        tenantPaymentMonthStatus(tenant, m,
            balance: balance, today: today, firstPaymentReceived: firstReceived),
    ];
    int count(PaymentMonthStatus s) => statuses.where((x) => x == s).length;
    final lateMonths = count(PaymentMonthStatus.late);
    final movedOutMonths = count(PaymentMonthStatus.movedOut);

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppTheme.backgroundSecondary,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppTheme.borderLight),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.payment_outlined, size: 18, color: AppTheme.primaryBlue),
              const SizedBox(width: 8),
              Text(
                'Payment History',
                style: Theme.of(context).textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.bold,
                      color: AppTheme.primaryBlue,
                    ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 16,
            runSpacing: 8,
            children: [
              _summaryChip(context, 'Payments made', '$paymentCount', Icons.check_circle_outline, AppTheme.success),
              _summaryChip(context, 'Paid', '${count(PaymentMonthStatus.paid)}', Icons.calendar_today, AppTheme.success),
              _summaryChip(context, 'Late', '$lateMonths', Icons.calendar_today, lateMonths > 0 ? AppTheme.error : AppTheme.textSecondary),
              _summaryChip(context, 'Moved out', '$movedOutMonths', Icons.exit_to_app, movedOutMonths > 0 ? AppTheme.warning : AppTheme.textSecondary),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            'Click a month to set status (${DateFormat('MMM yyyy').format(months.first)} – ${DateFormat('MMM yyyy').format(months.last)}):',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: AppTheme.textSecondary,
                  fontWeight: FontWeight.w500,
                ),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (var i = 0; i < months.length; i++)
                _monthChip(months[i], statuses[i]),
            ],
          ),
          if (statuses.any((s) =>
              s == PaymentMonthStatus.beforeMoveIn || s == PaymentMonthStatus.notRecorded)) ...[
            const SizedBox(height: 8),
            Text(
              'Grey months are before move-in or have nothing recorded; they are not counted as late.',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(color: AppTheme.textSecondary),
            ),
          ],
          const SizedBox(height: 16),
          Text(
            'Payments received',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: AppTheme.textSecondary,
                  fontWeight: FontWeight.w500,
                ),
          ),
          const SizedBox(height: 4),
          if (received.isEmpty)
            Text(
              'No payments on the ledger yet.',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(color: AppTheme.textSecondary),
            )
          else ...[
            for (final p in received.take(receivedListLimit)) _receivedRow(context, p),
            if (received.length > receivedListLimit)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  '${received.length - receivedListLimit} earlier '
                  '${received.length - receivedListLimit == 1 ? 'payment' : 'payments'} on the ledger (View Ledger).',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(color: AppTheme.textSecondary),
                ),
              ),
          ],
        ],
      ),
    );
  }

  /// One payment: when it came in, how (with the check number), and how much.
  Widget _receivedRow(BuildContext context, ReceivedPayment p) {
    final style = Theme.of(context).textTheme.bodySmall;
    final date = DateFormat(p.monthOnly ? 'MMM yyyy' : 'MMM d, yyyy').format(p.receivedOn);
    return Padding(
      key: ValueKey('received-payment-${p.ledgerEntryId}'),
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          SizedBox(width: 96, child: Text(date, style: style)),
          const SizedBox(width: 8),
          Expanded(child: Text(p.label, style: style, overflow: TextOverflow.ellipsis)),
          const SizedBox(width: 8),
          Text(
            '\$${p.amount.toStringAsFixed(2)}',
            style: style?.copyWith(fontWeight: FontWeight.w600, color: AppTheme.success),
          ),
        ],
      ),
    );
  }

  Widget _monthChip(DateTime month, PaymentMonthStatus status) {
    final color = statusColor(status);
    final label = DateFormat('MMM yy').format(month);
    final faded = status == PaymentMonthStatus.beforeMoveIn;
    return Tooltip(
      message: '${DateFormat('MMMM yyyy').format(month)}: ${statusLabel(status)}',
      child: Material(
        key: ValueKey('payment-month-${paymentMonthKey(month)}'),
        color: faded ? Colors.transparent : color.withValues(alpha: 0.15),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: faded ? const BorderSide(color: AppTheme.borderLight) : BorderSide.none,
        ),
        child: InkWell(
          onTap: onMonthTap == null ? null : () => onMonthTap!(month, status),
          borderRadius: BorderRadius.circular(20),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Text(
              label,
              style: TextStyle(
                fontSize: 12,
                color: color,
                fontWeight: faded ? FontWeight.w400 : FontWeight.w600,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _summaryChip(BuildContext context, String label, String value, IconData icon, Color color) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 16, color: color),
        const SizedBox(width: 6),
        Text(
          '$label: ',
          style: Theme.of(context).textTheme.bodySmall?.copyWith(color: AppTheme.textSecondary),
        ),
        Text(
          value,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                fontWeight: FontWeight.bold,
                color: color,
              ),
        ),
      ],
    );
  }
}
