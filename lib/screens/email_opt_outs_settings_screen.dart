import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/material.dart';
import 'package:sfcapp/services/email_suppression_admin_service.dart';
import 'package:sfcapp/theme/app_theme.dart';
import 'package:sfcapp/widgets/keyboard_scrollable.dart';

/// Lists email addresses that unsubscribed via List-Unsubscribe; staff can re-allow and optionally confirm by email.
class EmailOptOutsSettingsScreen extends StatefulWidget {
  final String facilityId;

  const EmailOptOutsSettingsScreen({
    super.key,
    required this.facilityId,
  });

  @override
  State<EmailOptOutsSettingsScreen> createState() => _EmailOptOutsSettingsScreenState();
}

class _EmailOptOutsSettingsScreenState extends State<EmailOptOutsSettingsScreen> {
  Future<List<FacilityEmailOptOutRow>>? _loadFuture;

  @override
  void initState() {
    super.initState();
    _loadFuture = EmailSuppressionAdminService.listSuppressions(widget.facilityId);
  }

  void _reload() {
    setState(() {
      _loadFuture = EmailSuppressionAdminService.listSuppressions(widget.facilityId);
    });
  }

  String _formatWhen(DateTime? t) {
    if (t == null) return '—';
    final local = t.toLocal();
    return '${local.year}-${local.month.toString().padLeft(2, '0')}-${local.day.toString().padLeft(2, '0')} '
        '${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}';
  }

  Future<void> _confirmReallow(FacilityEmailOptOutRow row) async {
    var sendConfirmation = true;
    final proceed = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setDialogState) {
          return AlertDialog(
            title: const Text('Allow emails again'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'This removes the email opt-out for:\n${row.emailLower}\n\n'
                  'They will receive automated and manual facility emails again (subject to your notification settings).',
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
                const SizedBox(height: 16),
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Send confirmation email'),
                  subtitle: const Text(
                    'Notifies them that they are opted back in and includes an unsubscribe link.',
                  ),
                  value: sendConfirmation,
                  onChanged: (v) => setDialogState(() => sendConfirmation = v ?? true),
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
                child: const Text('Allow emails'),
              ),
            ],
          );
        },
      ),
    );
    if (proceed != true || !mounted) return;

    try {
      final result = await EmailSuppressionAdminService.removeSuppression(
        facilityId: widget.facilityId,
        suppressId: row.suppressId,
        sendConfirmation: sendConfirmation,
      );
      if (!mounted) return;
      if (result.ok) {
        final msg = result.confirmationSent
            ? 'Opt-out removed. A confirmation email was sent.'
            : sendConfirmation
                ? 'Opt-out removed. Confirmation email could not be sent (check SendGrid configuration).'
                : 'Opt-out removed.';
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(msg), backgroundColor: AppTheme.success),
        );
        _reload();
      }
    } on FirebaseFunctionsException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(e.message ?? 'Request failed'),
          backgroundColor: AppTheme.error,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('$e'),
          backgroundColor: AppTheme.error,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<FacilityEmailOptOutRow>>(
      future: _loadFuture,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting && !snapshot.hasData) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snapshot.hasError) {
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text('Could not load list: ${snapshot.error}', textAlign: TextAlign.center),
                  const SizedBox(height: 16),
                  FilledButton(onPressed: _reload, child: const Text('Retry')),
                ],
              ),
            ),
          );
        }
        final rows = snapshot.data ?? [];

        return KeyboardScrollable(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Email opt-outs',
                  style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 8),
                Text(
                  'People who unsubscribed from non-essential facility emails using the link in a message. '
                  'SMS opt-outs (e.g. STOP) are not shown here.',
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: AppTheme.textSecondary),
                ),
                const SizedBox(height: 20),
                if (rows.isEmpty)
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text(
                        'No email opt-outs for this facility.',
                        style: Theme.of(context).textTheme.bodyLarge,
                      ),
                    ),
                  )
                else
                  Card(
                    clipBehavior: Clip.antiAlias,
                    child: Column(
                      children: [
                        for (var i = 0; i < rows.length; i++) ...[
                          if (i > 0) const Divider(height: 1),
                          ListTile(
                            title: Text(
                              rows[i].emailLower.isNotEmpty ? rows[i].emailLower : rows[i].suppressId,
                              style: const TextStyle(fontWeight: FontWeight.w500),
                            ),
                            subtitle: Text(
                              'Unsubscribed: ${_formatWhen(rows[i].unsubscribedAt)}'
                              '${rows[i].source != null ? ' · ${rows[i].source}' : ''}',
                            ),
                            trailing: FilledButton.tonal(
                              onPressed: () => _confirmReallow(rows[i]),
                              child: const Text('Allow emails'),
                            ),
                            isThreeLine: true,
                          ),
                        ],
                      ],
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}
