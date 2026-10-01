import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../models/ledger_entry_model.dart';
import '../theme/app_theme.dart';

class LedgerEntryCard extends StatelessWidget {
  final LedgerEntry entry;
  final VoidCallback? onVoid;

  /// Whether the charge sits on an invoice that has not been voided. Nothing
  /// on the ledger showed that an invoice had been generated, so an owner
  /// who had just made one asked where it went.
  final bool onInvoice;

  /// Set on a card dispute's row that still has money out: "Record payment
  /// for this dispute" books a payment against the dispute, not as rent.
  final VoidCallback? onRecordDisputePayment;

  const LedgerEntryCard({
    super.key,
    required this.entry,
    this.onVoid,
    this.onInvoice = false,
    this.onRecordDisputePayment,
  });

  @override
  Widget build(BuildContext context) {
    final isCharge = entry.isCharge;
    final isVoided = entry.status == LedgerEntryStatus.voided;
    final color = isVoided
        ? AppTheme.textTertiary
        : (isCharge ? AppTheme.error : AppTheme.success);

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Row(
          children: [
            // Icon
            Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                color: color.withOpacity(0.1),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Icon(
                isCharge ? Icons.add_circle_outline : Icons.remove_circle_outline,
                color: color,
              ),
            ),
            const SizedBox(width: 16),

            // Entry Details
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        // A Wrap, not a Row: beside the type name the "On
                        // invoice" chip drops under it on a phone instead of
                        // pushing the amount off the card.
                        child: Wrap(
                          spacing: 8,
                          runSpacing: 4,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            Text(
                              entry.typeDisplayName,
                              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                                fontWeight: FontWeight.w600,
                                decoration: isVoided ? TextDecoration.lineThrough : null,
                              ),
                            ),
                            if (onInvoice) _chip('On invoice', AppTheme.info),
                          ],
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        entry.formattedAmount,
                        style: Theme.of(context).textTheme.titleMedium?.copyWith(
                          color: color,
                          fontWeight: FontWeight.bold,
                          decoration: isVoided ? TextDecoration.lineThrough : null,
                        ),
                      ),
                    ],
                  ),
                  if (entry.description != null && entry.description!.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text(
                      entry.description!,
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: AppTheme.textSecondary,
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                  const SizedBox(height: 8),
                  // The dates wrap onto a second line when the card is
                  // narrow, with the status chip staying at the right. As
                  // one Row this overflowed a phone-width card whenever the
                  // charge had a due date (move-in and monthly rent do).
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: Wrap(
                          spacing: 16,
                          runSpacing: 4,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            _dated(
                              context,
                              Icons.calendar_today,
                              DateFormat('MM/dd/yyyy').format(entry.entryDate),
                            ),
                            if (entry.dueDate != null)
                              _dated(
                                context,
                                Icons.event,
                                'Due: ${DateFormat('MM/dd/yyyy').format(entry.dueDate!)}',
                              ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 8),
                      _chip(entry.statusDisplayName, _getStatusColor(entry.status)),
                    ],
                  ),
                  if (entry.referenceId != null) ...[
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        Icon(Icons.link, size: 12, color: AppTheme.textTertiary),
                        const SizedBox(width: 4),
                        Text(
                          'Ref: ${entry.referenceId!.substring(0, 8)}...',
                          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: AppTheme.textTertiary,
                            fontFamily: 'monospace',
                          ),
                        ),
                      ],
                    ),
                  ],
                  if (onRecordDisputePayment != null) ...[
                    const SizedBox(height: 4),
                    TextButton.icon(
                      onPressed: onRecordDisputePayment,
                      icon: const Icon(Icons.payments_outlined, size: 18),
                      label: const Text('Record payment for this dispute'),
                      style: TextButton.styleFrom(
                        padding: EdgeInsets.zero,
                        visualDensity: VisualDensity.compact,
                      ),
                    ),
                  ],
                ],
              ),
            ),

            // Actions
            if (onVoid != null && entry.status != LedgerEntryStatus.voided)
              IconButton(
                icon: const Icon(Icons.cancel_outlined),
                color: AppTheme.error,
                onPressed: onVoid,
                tooltip: 'Void Entry',
              ),
          ],
        ),
      ),
    );
  }

  /// An icon and a date. The text may shrink, so a date wider than the room
  /// left beside the status chip wraps instead of overflowing the card.
  Widget _dated(BuildContext context, IconData icon, String text) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 14, color: AppTheme.textTertiary),
        const SizedBox(width: 4),
        Flexible(
          child: Text(
            text,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: AppTheme.textTertiary,
            ),
          ),
        ),
      ],
    );
  }

  Widget _chip(String label, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withOpacity(0.1),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 11,
          color: color,
          fontWeight: FontWeight.w500,
        ),
      ),
    );
  }

  Color _getStatusColor(LedgerEntryStatus status) {
    switch (status) {
      case LedgerEntryStatus.pending:
        return AppTheme.warning;
      case LedgerEntryStatus.posted:
        return AppTheme.success;
      case LedgerEntryStatus.voided:
        return AppTheme.textTertiary;
    }
  }
}

