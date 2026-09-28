import 'package:flutter/material.dart';
import 'package:sfcapp/models/tenant_model.dart';
import 'package:sfcapp/utils/sms_consent.dart';

String _tenants(int n) => n == 1 ? '1 tenant' : '$n tenants';

String _dateLabel(DateTime d) =>
    '${d.month.toString().padLeft(2, '0')}/${d.day.toString().padLeft(2, '0')}/${d.year}';

/// Tenants List > Select Multiple > Record SMS consent. Asks how and when the
/// selected tenants agreed and has the owner confirm it, then returns the
/// consent to write (null when cancelled). [plan] says who is written and
/// who is skipped, so the owner sees that before confirming.
Future<SmsConsentUpdate?> showRecordSmsConsentDialog(
  BuildContext context, {
  required String facilityName,
  required SmsConsentBulkPlan plan,
  DateTime? today,
}) {
  return showDialog<SmsConsentUpdate>(
    context: context,
    builder: (_) => _RecordConsentDialog(
      facilityName: facilityName,
      plan: plan,
      today: today ?? DateTime.now(),
    ),
  );
}

class _RecordConsentDialog extends StatefulWidget {
  final String facilityName;
  final SmsConsentBulkPlan plan;
  final DateTime today;

  const _RecordConsentDialog({
    required this.facilityName,
    required this.plan,
    required this.today,
  });

  @override
  State<_RecordConsentDialog> createState() => _RecordConsentDialogState();
}

class _RecordConsentDialogState extends State<_RecordConsentDialog> {
  // Owned here, not by the caller: the dialog still builds the note field
  // during its closing animation.
  final noteCtrl = TextEditingController();
  SmsConsentMethod? method;
  late DateTime date = widget.today;
  var confirmed = false;

  @override
  void dispose() {
    noteCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext ctx) {
    final facilityName = widget.facilityName;
    final plan = widget.plan;
    final now = widget.today;
    final count = plan.toUpdate.length;
    final needsNote = method == SmsConsentMethod.other;
    final canSave = count > 0 &&
        method != null &&
        confirmed &&
        (!needsNote || noteCtrl.text.trim().isNotEmpty);
    return AlertDialog(
      title: const Text('Record SMS consent'),
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                count == 0
                    ? 'None of the selected tenants can be recorded.'
                    : '${_tenants(count)} will be marked as agreeing to texts '
                        'from $facilityName.',
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              ..._skipLines(plan),
              if (count > 0) ...[
                const SizedBox(height: 16),
                const Text('How did they agree?'),
                RadioGroup<SmsConsentMethod>(
                  groupValue: method,
                  onChanged: (m) => setState(() => method = m),
                  child: Column(
                    children: [
                      for (final m in SmsConsentMethod.values)
                        RadioListTile<SmsConsentMethod>(
                          key: Key('bulk-consent-method-${m.value}'),
                          value: m,
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          title: Text(m.label),
                        ),
                    ],
                  ),
                ),
                TextField(
                  key: const Key('bulk-consent-note'),
                  controller: noteCtrl,
                  onChanged: (_) => setState(() {}),
                  decoration: InputDecoration(
                    labelText: needsNote
                        ? 'Note (required for Other)'
                        : 'Note (optional)',
                    hintText: 'e.g. 2024 lease addendum, section 9',
                    border: const OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    const Expanded(child: Text('Date they agreed')),
                    OutlinedButton.icon(
                      key: const Key('bulk-consent-date'),
                      icon: const Icon(Icons.event, size: 18),
                      label: Text(_dateLabel(date)),
                      onPressed: () async {
                        final picked = await showDatePicker(
                          context: ctx,
                          initialDate: date,
                          firstDate: DateTime(2000),
                          lastDate: now,
                        );
                        if (picked != null) setState(() => date = picked);
                      },
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                CheckboxListTile(
                  key: const Key('bulk-consent-confirm'),
                  value: confirmed,
                  contentPadding: EdgeInsets.zero,
                  controlAffinity: ListTileControlAffinity.leading,
                  onChanged: (v) => setState(() => confirmed = v ?? false),
                  title: Text(
                      'These tenants agreed to receive texts from $facilityName'),
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
            key: const Key('bulk-consent-save'),
            onPressed: canSave
                ? () => Navigator.pop(
                      ctx,
                      SmsConsentUpdate.grant(
                        consentDate: date,
                        method: method,
                        note: noteCtrl.text,
                      ),
                    )
                : null,
            child: Text('Record consent for ${_tenants(count)}'),
          ),
      ],
    );
  }
}

/// Tenants List > Select Multiple > Remove SMS consent. True to go ahead.
Future<bool> showRemoveSmsConsentDialog(
  BuildContext context, {
  required String facilityName,
  required SmsConsentBulkPlan plan,
}) async {
  final count = plan.toUpdate.length;
  final left = plan.unchanged.length;
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Remove SMS consent'),
      content: Text(count == 0
          ? 'None of the selected tenants has SMS consent on file.'
          : 'Remove SMS consent for ${_tenants(count)}? $facilityName will '
              'stop texting them until consent is recorded again.'
              '${left == 0 ? '' : '\n\n${_tenants(left)} selected have no consent on file and are left as they are.'}'),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: Text(count == 0 ? 'Close' : 'Cancel'),
        ),
        if (count > 0)
          FilledButton(
            key: const Key('bulk-consent-remove'),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text('Remove consent for ${_tenants(count)}'),
          ),
      ],
    ),
  );
  return ok == true;
}

/// What a bulk record or removal did, with the names of anyone skipped.
Future<void> showSmsConsentBulkResult(
  BuildContext context, {
  required SmsConsentBulkPlan plan,
  required bool grant,
}) {
  final count = plan.toUpdate.length;
  return showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(grant ? 'SMS consent recorded' : 'SMS consent removed'),
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(grant
                  ? 'Consent recorded for ${_tenants(count)}.'
                  : 'Consent removed for ${_tenants(count)}.'),
              ..._skipLines(plan, withNames: true, grant: grant),
            ],
          ),
        ),
      ),
      actions: [
        FilledButton(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('OK'),
        ),
      ],
    ),
  );
}

List<Widget> _skipLines(
  SmsConsentBulkPlan plan, {
  bool withNames = false,
  bool grant = true,
}) {
  String names(List<TenantModel> ts) {
    if (!withNames) return '';
    final shown = ts.take(10).map((t) => t.name.trim().isEmpty ? t.id : t.name);
    final more = ts.length > 10 ? ', and ${ts.length - 10} more' : '';
    return ': ${shown.join(', ')}$more';
  }

  final lines = <String>[
    if (plan.unchanged.isNotEmpty)
      grant
          ? 'Skipped ${_tenants(plan.unchanged.length)} who already have consent '
              '(their original date is kept)${names(plan.unchanged)}'
          : 'Skipped ${_tenants(plan.unchanged.length)} with no consent on file'
              '${names(plan.unchanged)}',
    if (plan.noPhone.isNotEmpty)
      'Skipped ${_tenants(plan.noPhone.length)} with no mobile number on file'
          '${names(plan.noPhone)}',
    if (plan.optedOut.isNotEmpty)
      'Skipped ${_tenants(plan.optedOut.length)} who opted out themselves '
          '(texted STOP). Only they can opt back in, by texting START'
          '${names(plan.optedOut)}',
  ];
  return [
    for (final line in lines) ...[
      const SizedBox(height: 8),
      Text('• $line'),
    ],
  ];
}
