import 'package:flutter/material.dart';
import 'package:sfcapp/models/tenant_model.dart';
import 'package:sfcapp/theme/app_theme.dart';
import 'package:sfcapp/utils/sms_consent.dart';

/// "SMS ✓" / "SMS off" / "SMS opted out" on a tenant's card.
class SmsConsentChip extends StatelessWidget {
  final TenantModel tenant;
  const SmsConsentChip({super.key, required this.tenant});

  @override
  Widget build(BuildContext context) {
    final state = smsConsentState(tenant);
    final color = canReceiveTexts(tenant)
        ? AppTheme.success
        : state == SmsConsentState.optedOut
            ? AppTheme.error
            : AppTheme.textSecondary;
    return Tooltip(
      message: smsConsentSummary(tenant),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: color.withValues(alpha: 0.4)),
        ),
        child: Text(
          smsConsentChipLabel(tenant),
          style: TextStyle(
            color: color,
            fontSize: 12,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }
}

/// "N of M tenants can receive texts", above the tenant list.
String smsReachLine(List<TenantModel> tenants) {
  final reachable = tenants.where(canReceiveTexts).length;
  return '$reachable of ${tenants.length} '
      '${tenants.length == 1 ? 'tenant' : 'tenants'} can receive texts';
}
