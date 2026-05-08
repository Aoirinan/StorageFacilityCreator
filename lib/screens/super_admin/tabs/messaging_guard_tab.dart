import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:sfcapp/services/super_admin_data_service.dart';
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
                    'Messaging',
                    style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Email paying facility owners from the first card. Below that: platform kill switch and daily send caps (sendEmail, sendDigest, sendSMS, and mass emails each use the email cap). '
                    'Scheduled automations that do not use those callables are not counted here. Counters reset at UTC midnight.',
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: AppTheme.textSecondary,
                          height: 1.35,
                        ),
                  ),
                  const SizedBox(height: 20),
                  const FacilityOwnerBroadcastSection(),
                  const SizedBox(height: 28),
                  Text(
                    'Messaging guard',
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                  ),
                  const SizedBox(height: 12),
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

/// Email every unique facility owner (platform SendGrid identity) for outages or notices.
class FacilityOwnerBroadcastSection extends StatefulWidget {
  const FacilityOwnerBroadcastSection({super.key});

  @override
  State<FacilityOwnerBroadcastSection> createState() =>
      _FacilityOwnerBroadcastSectionState();
}

class _FacilityOwnerBroadcastSectionState
    extends State<FacilityOwnerBroadcastSection> {
  final _subject = TextEditingController();
  final _body = TextEditingController();
  final _confirm = TextEditingController();

  bool _includeInactive = false;
  /// `activePayingSubscribers` = facility owners with active $75/mo platform billing (default). `allOwners` = any owner.
  String _recipientScope = 'activePayingSubscribers';
  bool _loadingPreview = false;
  bool _sending = false;
  SuperAdminFacilityOwnerBroadcastPreview? _preview;
  String? _previewError;

  @override
  void initState() {
    super.initState();
    _refreshPreview();
  }

  @override
  void dispose() {
    _subject.dispose();
    _body.dispose();
    _confirm.dispose();
    super.dispose();
  }

  Future<void> _refreshPreview() async {
    setState(() {
      _loadingPreview = true;
      _previewError = null;
    });
    try {
      final p = await SuperAdminDataService.previewFacilityOwnerBroadcast(
        includeInactiveFacilities: _includeInactive,
        recipientScope: _recipientScope,
      );
      if (mounted) {
        setState(() {
          _preview = p;
          _loadingPreview = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _previewError = e.toString();
          _loadingPreview = false;
        });
      }
    }
  }

  Future<void> _send() async {
    final subject = _subject.text.trim();
    final body = _body.text.trim();
    if (subject.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Enter a subject.'),
          backgroundColor: AppTheme.error,
        ),
      );
      return;
    }
    if (body.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Enter a message body.'),
          backgroundColor: AppTheme.error,
        ),
      );
      return;
    }
    if (_confirm.text.trim() != 'BROADCAST') {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Type BROADCAST in the confirmation field to send.'),
          backgroundColor: AppTheme.error,
        ),
      );
      return;
    }

    setState(() => _sending = true);
    try {
      final result = await SuperAdminDataService.sendFacilityOwnerBroadcast(
        subject: subject,
        text: body,
        acknowledgment: _confirm.text.trim(),
        includeInactiveFacilities: _includeInactive,
        recipientScope: _recipientScope,
      );
      if (!mounted) return;
      setState(() => _sending = false);
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Broadcast finished'),
          content: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'Sent: ${result.sent} of ${result.totalRecipients}. '
                  'Failures: ${result.failureCount}.',
                ),
                if (result.failures.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  Text(
                    'First failures:',
                    style: Theme.of(ctx).textTheme.titleSmall,
                  ),
                  const SizedBox(height: 8),
                  ...result.failures.take(12).map(
                        (f) => Padding(
                          padding: const EdgeInsets.only(bottom: 6),
                          child: Text(
                            '${f.email}: ${f.error}',
                            style: Theme.of(ctx).textTheme.bodySmall,
                          ),
                        ),
                      ),
                ],
              ],
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
      _confirm.clear();
      await _refreshPreview();
    } on FirebaseFunctionsException catch (e) {
      if (mounted) {
        setState(() => _sending = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(e.message ?? e.code),
            backgroundColor: AppTheme.error,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() => _sending = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(e.toString()),
            backgroundColor: AppTheme.error,
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Mass email to facility owners',
              style: Theme.of(context).textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
            ),
            const SizedBox(height: 8),
            Text(
              'Sends one platform email per unique owner address (deduped). '
              'Default audience is paying subscribers only: account subscription status active, '
              'or per-facility platform subscription active (the standard \$75/mo product). '
              'Uses the same daily email cap as other callable sends; raise the cap above if needed. '
              'Does not use per-facility SendGrid footers or tenant unsubscribe lists.',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: AppTheme.textSecondary,
                    height: 1.35,
                  ),
            ),
            const SizedBox(height: 16),
            DropdownButtonFormField<String>(
              value: _recipientScope,
              decoration: const InputDecoration(
                labelText: 'Who receives this',
                border: OutlineInputBorder(),
              ),
              items: const [
                DropdownMenuItem(
                  value: 'activePayingSubscribers',
                  child: Text('Paying subscribers only (\$75/mo, active)'),
                ),
                DropdownMenuItem(
                  value: 'allOwners',
                  child: Text('All facility owners (any subscription state)'),
                ),
              ],
              onChanged: _sending
                  ? null
                  : (v) {
                      if (v == null) return;
                      setState(() => _recipientScope = v);
                      _refreshPreview();
                    },
            ),
            const SizedBox(height: 16),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Include archived facilities'),
              subtitle: const Text(
                'When on, owners of inactive (archived) facilities are included.',
              ),
              value: _includeInactive,
              onChanged: _sending
                  ? null
                  : (v) {
                      setState(() => _includeInactive = v);
                      _refreshPreview();
                    },
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                FilledButton.tonalIcon(
                  onPressed: _loadingPreview || _sending ? null : _refreshPreview,
                  icon: _loadingPreview
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.refresh, size: 18),
                  label: const Text('Refresh counts'),
                ),
                const SizedBox(width: 16),
                if (_preview != null)
                  Text(
                    '${_preview!.recipientCount} recipients · '
                    '${_preview!.uniqueOwnerUids} owner UIDs · '
                    '${_preview!.facilityDocuments} facility docs',
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
              ],
            ),
            if (_previewError != null) ...[
              const SizedBox(height: 8),
              Text(
                _previewError!,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: AppTheme.error,
                    ),
              ),
            ],
            const SizedBox(height: 20),
            TextField(
              controller: _subject,
              enabled: !_sending,
              decoration: const InputDecoration(
                labelText: 'Subject',
                border: OutlineInputBorder(),
              ),
              textCapitalization: TextCapitalization.sentences,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _body,
              enabled: !_sending,
              decoration: const InputDecoration(
                labelText: 'Message (plain text)',
                hintText: 'Shown as the main body; line breaks preserved.',
                alignLabelWithHint: true,
                border: OutlineInputBorder(),
              ),
              minLines: 5,
              maxLines: 14,
              textCapitalization: TextCapitalization.sentences,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _confirm,
              enabled: !_sending,
              decoration: const InputDecoration(
                labelText: 'Confirmation',
                hintText: 'Type BROADCAST to enable Send',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: _sending ? null : _send,
              icon: _sending
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : const Icon(Icons.send),
              label: Text(
                _sending
                    ? 'Sending…'
                    : _recipientScope == 'activePayingSubscribers'
                        ? 'Send to paying subscribers'
                        : 'Send to all owners',
              ),
            ),
          ],
        ),
      ),
    );
  }
}
