import 'package:flutter/material.dart';
import 'package:sfcapp/theme/app_theme.dart';

/// Canonical values for `FacilityModel.paymentProcessor`.
class PaymentProcessor {
  static const String stripe = 'stripe';
  static const String square = 'square';

  /// Square's backend isn't built yet (M2+). Until then the option is shown so
  /// owners know it's coming, but it can't be selected.
  static const bool squareAvailable = false;

  const PaymentProcessor._();
}

/// Lets a facility owner pick who processes their tenant payments.
///
/// Used in two places, which is why it takes a plain value/callback rather than
/// talking to Firestore itself: the facility-creation wizard (where there is no
/// facility document yet) and Billing → Payment Processing (where there is).
///
/// [selected] is the current `paymentProcessor` value — null means "not decided
/// yet", which is a legitimate resting state: owners can skip this and come back
/// via Billing → Payment Processing.
class PaymentProcessorChooser extends StatelessWidget {
  final String? selected;
  final ValueChanged<String?> onChanged;

  /// Whether to offer "I'll decide later". The wizard allows deferring; the
  /// Settings flow doesn't re-offer it once the owner is actively choosing.
  final bool allowDefer;

  const PaymentProcessorChooser({
    super.key,
    required this.selected,
    required this.onChanged,
    this.allowDefer = true,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _option(
          context,
          value: PaymentProcessor.stripe,
          title: 'Stripe',
          subtitle:
              'Fastest setup. Cards, autopay, and online payments. Recommended '
              'if you don\'t already take payments somewhere else.',
          enabled: true,
        ),
        const SizedBox(height: 12),
        _option(
          context,
          value: PaymentProcessor.square,
          title: 'Square',
          subtitle: PaymentProcessor.squareAvailable
              ? 'Connect the Square account you already use.'
              : 'Coming soon — choose Stripe for now, you can switch later.',
          enabled: PaymentProcessor.squareAvailable,
        ),
        if (allowDefer) ...[
          const SizedBox(height: 12),
          _option(
            context,
            value: null,
            title: 'I\'ll decide later',
            subtitle:
                'Set this up anytime from Billing → Payment Processing. You '
                'can still add units and tenants in the meantime.',
            enabled: true,
          ),
        ],
      ],
    );
  }

  Widget _option(
    BuildContext context, {
    required String? value,
    required String title,
    required String subtitle,
    required bool enabled,
  }) {
    final isSelected = selected == value;
    final cs = Theme.of(context).colorScheme;

    return Opacity(
      opacity: enabled ? 1.0 : 0.55,
      child: InkWell(
        onTap: enabled ? () => onChanged(value) : null,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: isSelected ? cs.primary : AppTheme.textTertiary.withValues(alpha: 0.35),
              width: isSelected ? 2 : 1,
            ),
            color: isSelected ? cs.primary.withValues(alpha: 0.06) : null,
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Indicator only — the whole row is the tap target (InkWell above),
              // which also avoids Flutter's deprecated Radio group API.
              Icon(
                isSelected
                    ? Icons.radio_button_checked
                    : Icons.radio_button_unchecked,
                color: isSelected ? cs.primary : AppTheme.textTertiary,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      subtitle,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: AppTheme.textSecondary,
                          ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
