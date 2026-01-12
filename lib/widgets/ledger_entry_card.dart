import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../models/ledger_entry_model.dart';
import '../theme/app_theme.dart';

class LedgerEntryCard extends StatelessWidget {
  final LedgerEntry entry;
  final VoidCallback? onVoid;

  const LedgerEntryCard({
    super.key,
    required this.entry,
    this.onVoid,
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
                        child: Text(
                          entry.typeDisplayName,
                          style: Theme.of(context).textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w600,
                            decoration: isVoided ? TextDecoration.lineThrough : null,
                          ),
                        ),
                      ),
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
                  Row(
                    children: [
                      Icon(Icons.calendar_today, size: 14, color: AppTheme.textTertiary),
                      const SizedBox(width: 4),
                      Text(
                        DateFormat('MM/dd/yyyy').format(entry.entryDate),
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: AppTheme.textTertiary,
                        ),
                      ),
                      if (entry.dueDate != null) ...[
                        const SizedBox(width: 16),
                        Icon(Icons.event, size: 14, color: AppTheme.textTertiary),
                        const SizedBox(width: 4),
                        Text(
                          'Due: ${DateFormat('MM/dd/yyyy').format(entry.dueDate!)}',
                          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: AppTheme.textTertiary,
                          ),
                        ),
                      ],
                      const Spacer(),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                        decoration: BoxDecoration(
                          color: _getStatusColor(entry.status).withOpacity(0.1),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          entry.statusDisplayName,
                          style: TextStyle(
                            fontSize: 11,
                            color: _getStatusColor(entry.status),
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),
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

