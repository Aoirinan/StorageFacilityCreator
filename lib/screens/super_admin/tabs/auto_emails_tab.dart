import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:sfcapp/theme/app_theme.dart';

/// One automated platform-to-owner email, as recorded by the onboarding
/// trigger. Suppressed sends are recorded too, so the pre-launch gate is
/// visible here rather than silently swallowing mail.
class PlatformEmailLog {
  final String id;
  final String accountId;
  final String ownerEmail;
  final String? ownerName;
  final String type;
  final String to;
  final String subject;
  final String previewText;
  final String status;
  final String? skippedReason;
  final String? providerMessageId;
  final String? errorMessage;
  final String trigger;
  final DateTime? createdAt;
  final DateTime? sentAt;

  const PlatformEmailLog({
    required this.id,
    required this.accountId,
    required this.ownerEmail,
    required this.ownerName,
    required this.type,
    required this.to,
    required this.subject,
    required this.previewText,
    required this.status,
    required this.skippedReason,
    required this.providerMessageId,
    required this.errorMessage,
    required this.trigger,
    required this.createdAt,
    required this.sentAt,
  });

  factory PlatformEmailLog.fromFirestore(
      QueryDocumentSnapshot<Map<String, dynamic>> doc) {
    final d = doc.data();
    DateTime? ts(String key) => (d[key] as Timestamp?)?.toDate();
    return PlatformEmailLog(
      id: doc.id,
      accountId: (d['accountId'] ?? '').toString(),
      ownerEmail: (d['ownerEmail'] ?? '').toString(),
      ownerName: d['ownerName'] as String?,
      type: (d['type'] ?? '').toString(),
      to: (d['to'] ?? '').toString(),
      subject: (d['subject'] ?? '').toString(),
      previewText: (d['previewText'] ?? '').toString(),
      status: (d['status'] ?? '').toString(),
      skippedReason: d['skippedReason'] as String?,
      providerMessageId: d['providerMessageId'] as String?,
      errorMessage: d['errorMessage'] as String?,
      trigger: (d['trigger'] ?? 'automatic').toString(),
      createdAt: ts('createdAt'),
      sentAt: ts('sentAt'),
    );
  }

  String get typeLabel {
    switch (type) {
      case 'account_under_review':
        return 'Signup received';
      case 'account_approved':
        return 'Account approved';
      case 'new_account_admin_alert':
        return 'Admin alert';
      default:
        return type;
    }
  }
}

/// Super-admin view of the automated onboarding emails: what went out, what
/// the pre-launch gate held back, and what failed.
class AutoEmailsTab extends StatefulWidget {
  const AutoEmailsTab({super.key});

  @override
  State<AutoEmailsTab> createState() => _AutoEmailsTabState();
}

class _AutoEmailsTabState extends State<AutoEmailsTab> {
  String _search = '';
  String _statusFilter = 'all';

  Stream<List<PlatformEmailLog>> get _stream {
    return FirebaseFirestore.instance
        .collection('platformEmailLogs')
        .orderBy('createdAt', descending: true)
        .limit(400)
        .snapshots()
        .map((snap) =>
            snap.docs.map(PlatformEmailLog.fromFirestore).toList());
  }

  List<PlatformEmailLog> _filter(List<PlatformEmailLog> all) {
    final q = _search.trim().toLowerCase();
    return all.where((r) {
      if (_statusFilter != 'all' && r.status != _statusFilter) return false;
      if (q.isEmpty) return true;
      return r.ownerEmail.toLowerCase().contains(q) ||
          (r.ownerName?.toLowerCase().contains(q) ?? false) ||
          r.to.toLowerCase().contains(q) ||
          r.subject.toLowerCase().contains(q) ||
          r.previewText.toLowerCase().contains(q) ||
          r.typeLabel.toLowerCase().contains(q) ||
          r.accountId.toLowerCase().contains(q) ||
          (r.providerMessageId?.toLowerCase().contains(q) ?? false);
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<PlatformEmailLog>>(
      stream: _stream,
      builder: (context, snap) {
        if (snap.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snap.hasError) {
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Text(
                'Could not load automated emails.\n\n${snap.error}',
                textAlign: TextAlign.center,
              ),
            ),
          );
        }
        final all = snap.data ?? [];
        final filtered = _filter(all);

        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _toolbar(all, filtered.length),
            Expanded(
              child: filtered.isEmpty
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Text(
                          all.isEmpty
                              ? 'No automated emails yet. Owner onboarding mail is recorded here the moment an account is created or approved.'
                              : 'No entries match your search.',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: Colors.grey.shade600),
                        ),
                      ),
                    )
                  : ListView.separated(
                      padding: const EdgeInsets.all(16),
                      itemCount: filtered.length,
                      separatorBuilder: (_, __) => const SizedBox(height: 10),
                      itemBuilder: (context, i) => _LogCard(
                        log: filtered[i],
                        onOpenDetail: () => _openDetail(filtered[i]),
                      ),
                    ),
            ),
          ],
        );
      },
    );
  }

  Widget _toolbar(List<PlatformEmailLog> all, int shown) {
    final skipped = all.where((e) => e.status == 'skipped').length;
    final failed = all.where((e) => e.status == 'failed').length;
    return Material(
      color: Colors.white,
      elevation: 1,
      child: Column(
        children: [
          if (skipped > 0 || failed > 0)
            Container(
              width: double.infinity,
              color: failed > 0
                  ? AppTheme.error.withValues(alpha: 0.08)
                  : Colors.amber.withValues(alpha: 0.15),
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
              child: Text(
                [
                  if (failed > 0) '$failed failed to send',
                  if (skipped > 0)
                    '$skipped held back by the pre-launch gate (appConfig/onboarding.ownerEmailsEnabled)',
                ].join('  ·  '),
                style: const TextStyle(fontSize: 13),
              ),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    decoration: const InputDecoration(
                      hintText: 'Search owner, subject, account, message id…',
                      prefixIcon: Icon(Icons.search, size: 20),
                      isDense: true,
                      border: OutlineInputBorder(),
                      contentPadding:
                          EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                    ),
                    onChanged: (v) => setState(() => _search = v),
                  ),
                ),
                const SizedBox(width: 12),
                DropdownButton<String>(
                  value: _statusFilter,
                  onChanged: (v) =>
                      setState(() => _statusFilter = v ?? 'all'),
                  items: const [
                    DropdownMenuItem(value: 'all', child: Text('All statuses')),
                    DropdownMenuItem(value: 'sent', child: Text('Sent')),
                    DropdownMenuItem(value: 'skipped', child: Text('Held back')),
                    DropdownMenuItem(value: 'failed', child: Text('Failed')),
                  ],
                ),
                const SizedBox(width: 16),
                Text(
                  '$shown / ${all.length}',
                  style: TextStyle(color: Colors.grey.shade700, fontSize: 13),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  void _openDetail(PlatformEmailLog log) {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(log.typeLabel),
        content: SizedBox(
          width: 560,
          child: SingleChildScrollView(
            child: SelectableText(
              _detailText(log),
              style: const TextStyle(fontSize: 13, height: 1.4),
            ),
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('Close')),
        ],
      ),
    );
  }

  String _detailText(PlatformEmailLog log) {
    String when(DateTime? d) =>
        d != null ? DateFormat.yMMMd().add_jm().format(d) : '—';
    final buf = StringBuffer();
    buf.writeln('Type: ${log.typeLabel}');
    buf.writeln('Status: ${log.status}');
    if (log.skippedReason != null) {
      buf.writeln('Held back because: ${log.skippedReason}');
    }
    if (log.errorMessage != null) buf.writeln('Error: ${log.errorMessage}');
    buf.writeln('Sent to: ${log.to}');
    buf.writeln('Owner: ${log.ownerName ?? '(no name on file)'} <${log.ownerEmail}>');
    buf.writeln('Account: ${log.accountId}');
    buf.writeln('Trigger: ${log.trigger}');
    buf.writeln('Recorded: ${when(log.createdAt)}');
    buf.writeln('Sent at: ${when(log.sentAt)}');
    buf.writeln('SendGrid id: ${log.providerMessageId ?? '—'}');
    buf.writeln('');
    buf.writeln('Subject: ${log.subject}');
    buf.writeln('');
    buf.writeln(log.previewText);
    return buf.toString();
  }
}

class _LogCard extends StatelessWidget {
  final PlatformEmailLog log;
  final VoidCallback onOpenDetail;

  const _LogCard({required this.log, required this.onOpenDetail});

  @override
  Widget build(BuildContext context) {
    final (color, icon, label) = switch (log.status) {
      'sent' => (AppTheme.success, Icons.check_circle_outline, 'Sent'),
      'skipped' => (Colors.orange.shade700, Icons.pause_circle_outline, 'Held back'),
      'failed' => (AppTheme.error, Icons.error_outline, 'Failed'),
      _ => (Colors.grey, Icons.mail_outline, log.status),
    };
    final when = log.createdAt != null
        ? DateFormat.MMMd().add_jm().format(log.createdAt!)
        : '—';

    return Card(
      margin: EdgeInsets.zero,
      child: ListTile(
        onTap: onOpenDetail,
        leading: Icon(icon, color: color),
        title: Text(
          log.subject.isNotEmpty ? log.subject : log.typeLabel,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 2),
            Text('${log.typeLabel} · $label · $when'),
            Text(
              log.to,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: Colors.grey.shade700),
            ),
            if (log.trigger == 'resend')
              Text('Resent manually',
                  style: TextStyle(color: Colors.grey.shade600, fontSize: 12)),
          ],
        ),
        trailing: const Icon(Icons.chevron_right),
      ),
    );
  }
}
