import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import 'package:sfcapp/theme/app_theme.dart';
import 'package:sfcapp/utils/breakpoints.dart';
import 'package:sfcapp/utils/invoice_summary.dart';

/// The strip of four figures above the Invoices tab's list: Invoices, Paid,
/// Overdue and Unpaid (see [InvoiceSummary] for what each counts).
///
/// Nothing in it is cut short with an ellipsis. The cards sit four across only
/// when each gets [minCardWidth]; below that they go two by two. Labels wrap,
/// and an amount too wide for its card is scaled down rather than cut.
class InvoiceSummaryCards extends StatelessWidget {
  const InvoiceSummaryCards({super.key, required this.summary});

  final InvoiceSummary summary;

  /// The narrowest card that still gets four across.
  static const double minCardWidth = 150;

  static final NumberFormat _money =
      NumberFormat.currency(locale: 'en_US', symbol: r'$', decimalDigits: 2);

  @override
  Widget build(BuildContext context) {
    final isPhone = MediaQuery.sizeOf(context).width < Breakpoints.xs;
    final gap = isPhone ? 6.0 : 12.0;
    final drafts = summary.unpaidDrafts;

    final cards = <Widget>[
      _SummaryCard(
        key: const ValueKey('invoice-summary-invoices'),
        label: 'Invoices',
        value: summary.count.toString(),
        icon: Icons.receipt,
        compact: isPhone,
      ),
      _SummaryCard(
        key: const ValueKey('invoice-summary-paid'),
        label: 'Paid',
        value: summary.paid.toString(),
        icon: Icons.check_circle,
        color: AppTheme.success,
        compact: isPhone,
      ),
      _SummaryCard(
        key: const ValueKey('invoice-summary-overdue'),
        label: 'Overdue',
        value: summary.overdue.toString(),
        icon: Icons.warning,
        color: AppTheme.error,
        compact: isPhone,
      ),
      _SummaryCard(
        key: const ValueKey('invoice-summary-unpaid'),
        label: 'Unpaid',
        value: _money.format(summary.unpaidAmount),
        caption: drafts == 0
            ? null
            : 'incl. $drafts ${drafts == 1 ? 'draft' : 'drafts'}',
        icon: Icons.attach_money,
        color: AppTheme.warning,
        compact: isPhone,
      ),
    ];

    return Container(
      padding: EdgeInsets.all(isPhone ? 12 : 16),
      decoration: const BoxDecoration(
        color: AppTheme.backgroundLight,
        border: Border(bottom: BorderSide(color: AppTheme.borderLight)),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final fourAcross =
              constraints.maxWidth >= 4 * minCardWidth + 3 * gap;
          if (fourAcross) return _row(cards, gap);
          return Column(
            children: [
              _row(cards.sublist(0, 2), gap),
              SizedBox(height: gap),
              _row(cards.sublist(2), gap),
            ],
          );
        },
      ),
    );
  }

  /// [cards] side by side, equal widths and equal heights.
  static Widget _row(List<Widget> cards, double gap) {
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var i = 0; i < cards.length; i++) ...[
            if (i > 0) SizedBox(width: gap),
            Expanded(child: cards[i]),
          ],
        ],
      ),
    );
  }
}

class _SummaryCard extends StatelessWidget {
  const _SummaryCard({
    super.key,
    required this.label,
    required this.value,
    required this.icon,
    required this.compact,
    this.caption,
    this.color,
  });

  final String label;
  final String value;
  final String? caption;
  final IconData icon;
  final Color? color;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: EdgeInsets.all(compact ? 10 : 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon,
                color: color ?? AppTheme.primaryBlue, size: compact ? 20 : 22),
            SizedBox(width: compact ? 8 : 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    label,
                    style: textTheme.bodySmall?.copyWith(
                      color: AppTheme.textSecondary,
                      fontSize: compact ? 11 : null,
                    ),
                  ),
                  SizedBox(height: compact ? 2 : 4),
                  // A long amount shrinks to fit its card instead of losing
                  // its last digits to an ellipsis.
                  FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.centerLeft,
                    child: Text(
                      value,
                      maxLines: 1,
                      softWrap: false,
                      style: textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                        color: color ?? AppTheme.textPrimary,
                        fontSize: compact ? 14 : null,
                      ),
                    ),
                  ),
                  if (caption != null) ...[
                    const SizedBox(height: 2),
                    Text(
                      caption!,
                      style: textTheme.bodySmall?.copyWith(
                        color: AppTheme.textSecondary,
                        fontSize: 11,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
