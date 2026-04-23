import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:sfcapp/theme/app_theme.dart';

/// Superadmin-only: platform kill switch and daily caps for staff sendEmail / sendDigest / sendSMS.
class MessagingGuardTab extends StatelessWidget {
  const MessagingGuardTab({super.key});

  Future<void> _editLimits(
    BuildContext context,
    int currentSms,
    int currentEmail,
  ) async {
    final smsCtl = TextEditingController(text: '$currentSms');
    final emailCtl = TextEditingController(text: '$currentEmail');
    try {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Daily caps (UTC calendar day)'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: smsCtl,
                decoration: const InputDecoration(
                  labelText: 'Max SMS (callable sends)',
                  border: OutlineInputBorder(),
                ),
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              ),
              const SizedBox(height: 12),
              TextField(
                controller: emailCtl,
                decoration: const InputDecoration(
                  labelText: 'Max email (callable sends)',
                  border: OutlineInputBorder(),
                ),
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Save'),
            ),
          ],
        ),
      );
      if (ok != true || !context.mounted) return;
      final s = int.tryParse(smsCtl.text.trim()) ?? currentSms;
      final e = int.tryParse(emailCtl.text.trim()) ?? currentEmail;
      if (s < 1 || s > 50000 || e < 1 || e > 50000) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Caps must be between 1 and 50000.'),
            backgroundColor: AppTheme.error,
          ),
        );
        return;
      }
      await FirebaseFirestore.instance
          .collection('configs')
          .doc('messagingGuard')
          .set(
        {
          'dailySmsLimit': s,
          'dailyEmailLimit': e,
        },
        SetOptions(merge: true),
      );
    } finally {
      smsCtl.dispose();
      emailCtl.dispose();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
        stream: FirebaseFirestore.instance
            .collection('configs')
            .doc('messagingGuard')
            .snapshots(),
        builder: (context, guardSnap) {
          return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
            stream: FirebaseFirestore.instance
                .collection('configs')
                .doc('messagingDailyRollup')
                .snapshots(),
            builder: (context, rollupSnap) {
              final guardData = guardSnap.data?.data() ?? {};
              final rollupData = rollupSnap.data?.data() ?? {};
              final enabled = guardData['enabled'] != false;
              final smsLimit =
                  (guardData['dailySmsLimit'] as num?)?.toInt() ?? 1000;
              final emailLimit =
                  (guardData['dailyEmailLimit'] as num?)?.toInt() ?? 1000;
              final smsSent = (rollupData['smsSent'] as num?)?.toInt() ?? 0;
              final emailSent = (rollupData['emailSent'] as num?)?.toInt() ?? 0;
              final date = rollupData['date'] as String? ?? '—';

              return ListView(
                children: [
                  Text(
                    'Messaging guard',
                    style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Staff-triggered sends only: sendEmail, sendDigest, and sendSMS (including SMS→email fallback). '
                    'Scheduled automations that do not use those callables are not counted here. '
                    'Counters reset at UTC midnight.',
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: AppTheme.textSecondary,
                          height: 1.35,
                        ),
                  ),
                  const SizedBox(height: 20),
                  Card(
                    child: SwitchListTile(
                      title: const Text('Staff messaging enabled'),
                      subtitle: const Text(
                        'When disabled, sendEmail, sendDigest, and sendSMS fail immediately for all users.',
                      ),
                      value: enabled,
                      onChanged: (v) {
                        FirebaseFirestore.instance
                            .collection('configs')
                            .doc('messagingGuard')
                            .set({'enabled': v}, SetOptions(merge: true));
                      },
                    ),
                  ),
                  const SizedBox(height: 16),
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Expanded(
                                child: Text(
                                  'Today (UTC): $date',
                                  style: Theme.of(context).textTheme.titleMedium,
                                ),
                              ),
                              TextButton.icon(
                                onPressed: () =>
                                    _editLimits(context, smsLimit, emailLimit),
                                icon: const Icon(Icons.edit, size: 18),
                                label: const Text('Edit caps'),
                              ),
                            ],
                          ),
                          const SizedBox(height: 12),
                          _metricRow(
                            context,
                            'SMS (callable)',
                            '$smsSent / $smsLimit',
                          ),
                          const SizedBox(height: 8),
                          _metricRow(
                            context,
                            'Email (callable)',
                            '$emailSent / $emailLimit',
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              );
            },
          );
        },
      ),
    );
  }

  Widget _metricRow(BuildContext context, String label, String value) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Text(
            label,
            style: Theme.of(context).textTheme.bodyLarge,
          ),
        ),
        Text(
          value,
          style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                fontWeight: FontWeight.w600,
              ),
        ),
      ],
    );
  }
}
