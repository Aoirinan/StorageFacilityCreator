import 'package:flutter/material.dart';
import 'package:sfcapp/models/stripe_connect_status_model.dart';
import 'package:sfcapp/theme/app_theme.dart';
import 'package:sfcapp/utils/stripe_connect_requirements.dart';

/// Shows outstanding Stripe Connect onboarding requirements in plain language.
class StripeConnectRequirementsChecklist extends StatelessWidget {
  final StripeConnectStatusModel status;
  final bool compact;

  const StripeConnectRequirementsChecklist({
    super.key,
    required this.status,
    this.compact = false,
  });

  @override
  Widget build(BuildContext context) {
    final fields = uniqueStripeConnectRequirements(
      currentlyDue: status.currentlyDue,
      pastDue: status.pastDue,
    );
    if (fields.isEmpty) return const SizedBox.shrink();

    final theme = Theme.of(context);
    final hasPastDue = status.pastDue.isNotEmpty;

    return Container(
      width: double.infinity,
      padding: EdgeInsets.all(compact ? 12 : 14),
      decoration: BoxDecoration(
        color: hasPastDue
            ? AppTheme.error.withValues(alpha: 0.08)
            : AppTheme.warning.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: hasPastDue ? AppTheme.error.withValues(alpha: 0.35) : AppTheme.warning.withValues(alpha: 0.4),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                hasPastDue ? Icons.error_outline : Icons.pending_outlined,
                size: 20,
                color: hasPastDue ? AppTheme.error : AppTheme.warning,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  hasPastDue
                      ? 'Action required — tenant payments are blocked until you complete:'
                      : 'Finish setup to accept tenant card payments:',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                    color: AppTheme.textPrimary,
                  ),
                ),
              ),
            ],
          ),
          SizedBox(height: compact ? 8 : 10),
          ...fields.map((field) => Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      status.pastDue.contains(field) ? Icons.close : Icons.circle_outlined,
                      size: 16,
                      color: status.pastDue.contains(field) ? AppTheme.error : AppTheme.textSecondary,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        stripeConnectRequirementLabel(field),
                        style: theme.textTheme.bodySmall?.copyWith(color: AppTheme.textPrimary),
                      ),
                    ),
                  ],
                ),
              )),
        ],
      ),
    );
  }
}
