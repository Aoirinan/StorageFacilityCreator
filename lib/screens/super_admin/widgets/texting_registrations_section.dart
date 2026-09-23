import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:sfcapp/services/texting_onboarding_service.dart';
import 'package:sfcapp/theme/app_theme.dart';

/// Super admin view of every facility's texting (A2P) registration: who is
/// waiting on platform approval, and what has been submitted, approved or
/// rejected recently. The same events are emailed to super admins by the
/// `notifyAdminsOfA2PChanges` function; this is where they can be seen after
/// the fact and acted on.
class TextingRegistrationsSection extends StatefulWidget {
  const TextingRegistrationsSection({super.key});

  @override
  State<TextingRegistrationsSection> createState() =>
      _TextingRegistrationsSectionState();
}

class _TextingRegistrationsSectionState
    extends State<TextingRegistrationsSection> {
  late Future<List<A2PAdminEvent>> _events = _loadEvents();
  final Set<String> _approving = {};

  Future<List<A2PAdminEvent>> _loadEvents() async {
    final result = await FirebaseFunctions.instance
        .httpsCallable('listA2PAdminEvents')
        .call({'limit': 50});
    final data = Map<String, dynamic>.from(result.data as Map);
    final raw = (data['events'] as List?) ?? const [];
    return raw
        .map((e) => A2PAdminEvent.fromMap(Map<String, dynamic>.from(e as Map)))
        .toList();
  }

  void _refresh() => setState(() => _events = _loadEvents());

  Future<void> _approve(String facilityId, String name) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Grant platform approval?'),
        content: Text(
          'Carriers have approved $name. Granting platform approval lets this '
          'facility text tenants from its own number.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Approve'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _approving.add(facilityId));
    try {
      await TextingOnboardingService.setPlatformApproval(
        facilityId: facilityId,
        approved: true,
      );
    } on FirebaseFunctionsException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(e.message ?? 'Approval failed.')),
        );
      }
    } finally {
      if (mounted) setState(() => _approving.remove(facilityId));
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                'Texting registrations',
                style: theme.textTheme.titleLarge
                    ?.copyWith(fontWeight: FontWeight.w600),
              ),
            ),
            IconButton(
              tooltip: 'Refresh',
              onPressed: _refresh,
              icon: const Icon(Icons.refresh),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          'Each facility registers under the platform Twilio account. Every '
          'submission and carrier decision is emailed to super admins and '
          'listed here.',
          style: theme.textTheme.bodyMedium
              ?.copyWith(color: AppTheme.textSecondary, height: 1.35),
        ),
        const SizedBox(height: 12),
        _awaitingApproval(context),
        const SizedBox(height: 16),
        Text('Recent activity', style: theme.textTheme.titleMedium),
        const SizedBox(height: 8),
        FutureBuilder<List<A2PAdminEvent>>(
          future: _events,
          builder: (context, snap) {
            if (snap.connectionState != ConnectionState.done) {
              return const Padding(
                padding: EdgeInsets.all(16),
                child: Center(child: CircularProgressIndicator()),
              );
            }
            if (snap.hasError) {
              return Card(
                child: ListTile(
                  leading: const Icon(Icons.error_outline,
                      color: AppTheme.error),
                  title: const Text('Could not load registration activity'),
                  subtitle: Text('${snap.error}'),
                ),
              );
            }
            final events = snap.data ?? const [];
            if (events.isEmpty) {
              return const Card(
                child: ListTile(
                  leading: Icon(Icons.inbox),
                  title: Text('No registration activity yet'),
                  subtitle: Text(
                    'Events appear here from the moment an owner saves '
                    'business details on their Texting page.',
                  ),
                ),
              );
            }
            return Column(
              children: [
                for (final e in events) ...[
                  _EventCard(event: e),
                  const SizedBox(height: 8),
                ],
              ],
            );
          },
        ),
      ],
    );
  }

  Widget _awaitingApproval(BuildContext context) {
    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: FirebaseFirestore.instance
          .collection('facilities')
          .where('a2pStatus', isEqualTo: 'approved')
          .snapshots(),
      builder: (context, snap) {
        final waiting = (snap.data?.docs ?? const [])
            .where((d) => d.data()['textingPlatformApproved'] != true)
            .toList();
        if (waiting.isEmpty) {
          return const Card(
            child: ListTile(
              leading: Icon(Icons.check_circle_outline,
                  color: AppTheme.success),
              title: Text('Nobody is waiting on platform approval'),
            ),
          );
        }
        return Card(
          color: AppTheme.warning.withValues(alpha: 0.08),
          child: Column(
            children: [
              const ListTile(
                leading: Icon(Icons.pending_actions, color: AppTheme.warning),
                title: Text(
                  'Waiting on your platform approval',
                  style: TextStyle(fontWeight: FontWeight.w600),
                ),
                subtitle: Text(
                  'Carriers approved these facilities. They cannot text from '
                  'their own number until you approve.',
                ),
              ),
              for (final doc in waiting)
                ListTile(
                  title: Text((doc.data()['name'] as String?) ?? doc.id),
                  subtitle: Text(doc.id),
                  trailing: _approving.contains(doc.id)
                      ? const SizedBox(
                          width: 24,
                          height: 24,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : FilledButton(
                          onPressed: () => _approve(
                            doc.id,
                            (doc.data()['name'] as String?) ?? doc.id,
                          ),
                          child: const Text('Approve'),
                        ),
                ),
            ],
          ),
        );
      },
    );
  }
}

class A2PAdminEvent {
  final String id;
  final String facilityId;
  final String? facilityName;
  final String? legalBusinessName;
  final List<({String kind, String headline, List<String> detail})> alerts;
  final String? emailStatus;
  final String? emailError;
  final DateTime? createdAt;

  const A2PAdminEvent({
    required this.id,
    required this.facilityId,
    required this.facilityName,
    required this.legalBusinessName,
    required this.alerts,
    required this.emailStatus,
    required this.emailError,
    required this.createdAt,
  });

  factory A2PAdminEvent.fromMap(Map<String, dynamic> m) {
    final ms = m['createdAtMs'];
    return A2PAdminEvent(
      id: m['id'] as String? ?? '',
      facilityId: m['facilityId'] as String? ?? '',
      facilityName: m['facilityName'] as String?,
      legalBusinessName: m['legalBusinessName'] as String?,
      alerts: ((m['alerts'] as List?) ?? const []).map((a) {
        final alert = Map<String, dynamic>.from(a as Map);
        return (
          kind: alert['kind'] as String? ?? '',
          headline: alert['headline'] as String? ?? '',
          detail: ((alert['detail'] as List?) ?? const [])
              .map((d) => '$d')
              .toList(),
        );
      }).toList(),
      emailStatus: m['emailStatus'] as String?,
      emailError: m['emailError'] as String?,
      createdAt:
          ms is num ? DateTime.fromMillisecondsSinceEpoch(ms.toInt()) : null,
    );
  }

  bool get isBad => alerts.any((a) =>
      a.kind.endsWith('_rejected') || a.kind == 'bundle_failed_check');

  bool get isGood => alerts.any((a) => a.kind.endsWith('_approved'));
}

class _EventCard extends StatelessWidget {
  final A2PAdminEvent event;

  const _EventCard({required this.event});

  @override
  Widget build(BuildContext context) {
    final (color, icon) = event.isBad
        ? (AppTheme.error, Icons.cancel_outlined)
        : event.isGood
            ? (AppTheme.success, Icons.check_circle_outline)
            : (AppTheme.info, Icons.send_outlined);
    final when = event.createdAt != null
        ? DateFormat.MMMd().add_jm().format(event.createdAt!)
        : '—';
    final email = switch (event.emailStatus) {
      'sent' => 'Emailed',
      'failed' => 'Email failed',
      'skipped' => 'Not emailed',
      _ => 'Email pending',
    };
    final name = event.facilityName ?? event.facilityId;

    return Card(
      margin: EdgeInsets.zero,
      child: ExpansionTile(
        leading: Icon(icon, color: color),
        title: Text(
          event.alerts.map((a) => a.headline).join(' · '),
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
        subtitle: Text('$name · $when · $email'),
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
        expandedCrossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (event.legalBusinessName != null)
            Text('Legal name: ${event.legalBusinessName}'),
          Text('Facility ID: ${event.facilityId}'),
          if (event.emailError != null)
            Text('Email: ${event.emailError}',
                style: const TextStyle(color: AppTheme.error)),
          for (final alert in event.alerts) ...[
            const SizedBox(height: 8),
            Text(alert.headline,
                style: const TextStyle(fontWeight: FontWeight.w600)),
            for (final line in alert.detail) Text('• $line'),
          ],
        ],
      ),
    );
  }
}
