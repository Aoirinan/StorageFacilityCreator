import 'package:flutter/material.dart';
import 'package:sfcapp/models/tenant_model.dart';
import 'package:sfcapp/services/paid_through_bulk_service.dart';
import 'package:sfcapp/utils/paid_through.dart';

String _tenants(int n) => n == 1 ? '1 tenant' : '$n tenants';

String _dateLabel(DateTime d) =>
    '${d.month.toString().padLeft(2, '0')}/${d.day.toString().padLeft(2, '0')}/${d.year}';

const _shortMonths = [
  'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
  'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
];

/// The month the owner picked in the bulk Paid through dialog.
typedef PaidThroughMonth = ({int year, int month});

/// The snackbar after a bulk Paid through fails. Large selections commit in
/// several batches, so a failure can come after some were saved: say how
/// many, not "Nothing was changed".
String paidThroughBulkFailureMessage(Object error, String friendly) {
  if (error is PaidThroughPartialFailure && error.committed > 0) {
    return '${error.committed} of ${error.total} saved; the rest were not. $friendly';
  }
  return 'Nothing was changed: $friendly';
}

/// What a bulk Paid through did, for the snackbar.
String paidThroughBulkDoneMessage(PaidThroughBulkPlan plan) {
  final d = plan.paidThrough;
  final done = 'Marked ${_tenants(plan.toUpdate.length)} paid through the end '
      'of ${paidThroughMonthLabel(d.year, d.month)}.';
  final later = plan.alreadyLater.length;
  if (later == 0) return done;
  return '$done ${_tenants(later)} already paid through a later date '
      '${later == 1 ? 'was' : 'were'} left as they are.';
}

/// Tenants List > Select Multiple > Paid through (N).
///
/// For an owner moving over from a paper ledger: mark everyone who is paid
/// up as paid through the end of a month in one step. The owner picks the
/// month (this month to start with), sees how many tenants will be marked
/// and who is skipped because they are already paid through a later date,
/// and confirms. Returns the month, or null when cancelled.
Future<PaidThroughMonth?> showPaidThroughBulkDialog(
  BuildContext context, {
  required List<TenantModel> tenants,
  DateTime? today,
}) {
  return showDialog<PaidThroughMonth>(
    context: context,
    builder: (_) => _PaidThroughBulkDialog(
      tenants: tenants,
      today: today ?? DateTime.now(),
    ),
  );
}

class _PaidThroughBulkDialog extends StatefulWidget {
  final List<TenantModel> tenants;
  final DateTime today;

  const _PaidThroughBulkDialog({required this.tenants, required this.today});

  @override
  State<_PaidThroughBulkDialog> createState() => _PaidThroughBulkDialogState();
}

class _PaidThroughBulkDialogState extends State<_PaidThroughBulkDialog> {
  late int year = widget.today.year;
  late int month = widget.today.month;
  var confirmed = false;

  @override
  Widget build(BuildContext ctx) {
    final plan = planPaidThroughBulk(widget.tenants, year: year, month: month);
    final count = plan.toUpdate.length;
    final end = plan.paidThrough;
    final monthLabel = paidThroughMonthLabel(year, month);
    final thisYear = widget.today.year;
    final years = [for (var y = thisYear - 2; y <= thisYear + 1; y++) y];
    final canSave = count > 0 && confirmed;

    return AlertDialog(
      title: const Text('Mark paid through'),
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Rent is paid up to and including the end of this month:',
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: DropdownButtonFormField<int>(
                      key: const Key('bulk-paid-through-month'),
                      initialValue: month,
                      decoration: const InputDecoration(
                        labelText: 'Month',
                        border: OutlineInputBorder(),
                        isDense: true,
                      ),
                      items: [
                        for (var m = 1; m <= 12; m++)
                          DropdownMenuItem(value: m, child: Text(_shortMonths[m - 1])),
                      ],
                      onChanged: (m) {
                        if (m == null) return;
                        // A new month is a new thing to confirm.
                        setState(() {
                          month = m;
                          confirmed = false;
                        });
                      },
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: DropdownButtonFormField<int>(
                      key: const Key('bulk-paid-through-year'),
                      initialValue: year,
                      decoration: const InputDecoration(
                        labelText: 'Year',
                        border: OutlineInputBorder(),
                        isDense: true,
                      ),
                      items: [
                        for (final y in years)
                          DropdownMenuItem(value: y, child: Text('$y')),
                      ],
                      onChanged: (y) {
                        if (y == null) return;
                        setState(() {
                          year = y;
                          confirmed = false;
                        });
                      },
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              Text(
                count == 0
                    ? 'None of the selected tenants can be marked: all are '
                        'already paid through a later date.'
                    : '${_tenants(count)} will be marked paid through the end '
                        'of $monthLabel (${_dateLabel(end)}).',
                key: const Key('bulk-paid-through-summary'),
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              if (plan.alreadyLater.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(
                  'Skipped ${_tenants(plan.alreadyLater.length)} already paid '
                  'through a later date (left as they are):',
                  key: const Key('bulk-paid-through-skipped'),
                ),
                for (final t in plan.alreadyLater.take(10))
                  Text(
                    '• ${t.name.trim().isEmpty ? t.id : t.name}'
                    '${t.paidThrough == null ? '' : ' (${_dateLabel(t.paidThrough!)})'}',
                  ),
                if (plan.alreadyLater.length > 10)
                  Text('• and ${plan.alreadyLater.length - 10} more'),
              ],
              if (count > 0) ...[
                const SizedBox(height: 12),
                CheckboxListTile(
                  key: const Key('bulk-paid-through-confirm'),
                  value: confirmed,
                  contentPadding: EdgeInsets.zero,
                  controlAffinity: ListTileControlAffinity.leading,
                  onChanged: (v) => setState(() => confirmed = v ?? false),
                  title: Text(
                    'These tenants have paid their rent through the end of $monthLabel',
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: Text(count == 0 ? 'Close' : 'Cancel'),
        ),
        if (count > 0)
          FilledButton(
            key: const Key('bulk-paid-through-save'),
            onPressed: canSave
                ? () => Navigator.pop<PaidThroughMonth>(
                      ctx,
                      (year: year, month: month),
                    )
                : null,
            child: Text('Mark ${_tenants(count)} paid'),
          ),
      ],
    );
  }
}
