import 'package:flutter/material.dart';
import 'package:sfcapp/theme/app_theme.dart';
import 'package:sfcapp/utils/sms_consent.dart';

/// The consent box on Create Tenant, Edit Tenant and Edit Contact
/// Information: one wording everywhere (see [smsConsentCheckboxLabel]).
///
/// [savedState] is the tenant's consent as saved (null for a new tenant). A
/// tenant's own opt-out locks the box. When the box is ticked for a tenant
/// with no consent on file yet, it asks how they agreed.
class SmsConsentCheckbox extends StatelessWidget {
  final String facilityName;
  final SmsConsentState? savedState;
  final bool value;
  final ValueChanged<bool> onChanged;
  final SmsConsentMethod? method;
  final ValueChanged<SmsConsentMethod?> onMethodChanged;
  final bool compact;

  const SmsConsentCheckbox({
    super.key,
    required this.facilityName,
    required this.savedState,
    required this.value,
    required this.onChanged,
    required this.method,
    required this.onMethodChanged,
    this.compact = false,
  });

  @override
  Widget build(BuildContext context) {
    final locked = savedState == SmsConsentState.optedOut;
    final newlyTicked = value && savedState != SmsConsentState.consented;
    final fontSize = compact ? 12.0 : 13.0;
    return Container(
      key: const Key('sms-consent-box'),
      padding: EdgeInsets.all(compact ? 10 : 12),
      decoration: BoxDecoration(
        color: AppTheme.backgroundSecondary,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppTheme.borderLight),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Checkbox(
                key: const Key('sms-consent-checkbox'),
                value: value && !locked,
                onChanged: locked ? null : (v) => onChanged(v ?? false),
              ),
              Expanded(
                child: GestureDetector(
                  onTap: locked ? null : () => onChanged(!value),
                  child: Padding(
                    padding: const EdgeInsets.only(top: 10),
                    child: locked
                        ? Text(
                            smsOptedOutText,
                            style: TextStyle(
                              fontSize: fontSize,
                              color: AppTheme.error,
                              fontWeight: FontWeight.w500,
                            ),
                          )
                        : Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                smsConsentCheckboxLabel(facilityName),
                                style: TextStyle(
                                  fontSize: fontSize,
                                  fontWeight: FontWeight.w500,
                                  color: AppTheme.textPrimary,
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                smsConsentHelperText,
                                style: TextStyle(
                                  fontSize: fontSize - 1,
                                  color: AppTheme.textSecondary,
                                ),
                              ),
                            ],
                          ),
                  ),
                ),
              ),
            ],
          ),
          if (newlyTicked && !locked) ...[
            const SizedBox(height: 8),
            Padding(
              padding: const EdgeInsets.only(left: 48),
              child: DropdownButtonFormField<SmsConsentMethod?>(
                key: const Key('sms-consent-method'),
                initialValue: method,
                isExpanded: true,
                decoration: const InputDecoration(
                  labelText: 'How did they agree? (optional)',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
                items: [
                  const DropdownMenuItem<SmsConsentMethod?>(
                    value: null,
                    child: Text('Not specified'),
                  ),
                  for (final m in SmsConsentMethod.values)
                    DropdownMenuItem<SmsConsentMethod?>(
                      value: m,
                      child: Text(m.label),
                    ),
                ],
                onChanged: onMethodChanged,
              ),
            ),
          ],
        ],
      ),
    );
  }
}
