import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:sfcapp/models/tenant_message_history_model.dart';
import 'package:sfcapp/theme/app_theme.dart';

/// Super-admin view of outbound email/SMS audit rows (`facilities/*/messageLogs`).
class MessageLogsTab extends StatefulWidget {
  const MessageLogsTab({super.key});

  @override
  State<MessageLogsTab> createState() => _MessageLogsTabState();
}

class _MessageLogsTabState extends State<MessageLogsTab> {
  String _search = '';

  Stream<List<TenantMessageHistoryModel>> get _stream {
    return FirebaseFirestore.instance
        .collectionGroup('messageLogs')
        .orderBy('createdAt', descending: true)
        .limit(400)
        .snapshots()
        .map((snap) => snap.docs
            .map((d) => TenantMessageHistoryModel.fromFirestore(d))
            .toList());
  }

  List<TenantMessageHistoryModel> _filter(List<TenantMessageHistoryModel> all) {
    final q = _search.trim().toLowerCase();
    if (q.isEmpty) return all;
    return all.where((r) {
      return r.facilityId.toLowerCase().contains(q) ||
          (r.tenantId?.toLowerCase().contains(q) ?? false) ||
          (r.tenantName?.toLowerCase().contains(q) ?? false) ||
          (r.tenantEmail?.toLowerCase().contains(q) ?? false) ||
          (r.tenantPhone?.toLowerCase().contains(q) ?? false) ||
          r.channel.toLowerCase().contains(q) ||
          r.source.toLowerCase().contains(q) ||
          r.direction.toLowerCase().contains(q) ||
          (r.subject?.toLowerCase().contains(q) ?? false) ||
          (r.previewText?.toLowerCase().contains(q) ?? false) ||
          r.message.toLowerCase().contains(q) ||
          (r.providerMessageId?.toLowerCase().contains(q) ?? false) ||
          (r.createdByEmail?.toLowerCase().contains(q) ?? false) ||
          (r.createdByUid?.toLowerCase().contains(q) ?? false);
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<TenantMessageHistoryModel>>(
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
                'Could not load message logs. Deploy the Firestore index for '
                'collection group `messageLogs` (createdAt desc) if this is a new query.\n\n'
                '${snap.error}',
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
            _toolbar(all.length, filtered.length),
            Expanded(
              child: filtered.isEmpty
                  ? Center(
                      child: Text(
                        _search.isNotEmpty
                            ? 'No entries match your search.'
                            : 'No message logs yet.',
                        style: TextStyle(color: Colors.grey.shade600),
                      ),
                    )
                  : ListView.separated(
                      padding: const EdgeInsets.all(16),
                      itemCount: filtered.length,
                      separatorBuilder: (_, __) => const SizedBox(height: 10),
                      itemBuilder: (context, i) => _MessageLogCard(
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

  Widget _toolbar(int total, int shown) {
    return Material(
      color: Colors.white,
      elevation: 1,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
        child: Row(
          children: [
            Expanded(
              child: TextField(
                decoration: const InputDecoration(
                  hintText: 'Search facility, tenant, subject, preview, provider id…',
                  prefixIcon: Icon(Icons.search, size: 20),
                  isDense: true,
                  border: OutlineInputBorder(),
                  contentPadding:
                      EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                ),
                onChanged: (v) => setState(() => _search = v),
              ),
            ),
            const SizedBox(width: 16),
            Text(
              '$shown / $total',
              style: TextStyle(color: Colors.grey.shade700, fontSize: 13),
            ),
          ],
        ),
      ),
    );
  }

  void _openDetail(TenantMessageHistoryModel log) {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Message log detail'),
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
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  String _detailText(TenantMessageHistoryModel log) {
    final buf = StringBuffer();
    buf.writeln(
        'Created: ${DateFormat.yMMMd().add_jm().format(log.createdAt)}');
    if (log.sentAt != log.createdAt) {
      buf.writeln('Sent: ${DateFormat.yMMMd().add_jm().format(log.sentAt)}');
    }
    buf.writeln('Facility: ${log.facilityId}');
    buf.writeln(
        'Channel: ${log.channel}  direction: ${log.direction}  source: ${log.source}');
    buf.writeln('Status: ${log.status.displayName}  provider: ${log.provider}');
    if ((log.errorCode ?? '').isNotEmpty || (log.errorMessage ?? '').isNotEmpty) {
      buf.writeln('Error: ${log.errorCode ?? '—'}  ${log.errorMessage ?? ''}');
    }
    buf.writeln(
        'Tenant: ${log.tenantName ?? '—'}  id: ${log.tenantId ?? '—'}');
    buf.writeln('Email: ${log.tenantEmail ?? '—'}  Phone: ${log.tenantPhone ?? '—'}');
    buf.writeln(
        'Created by: ${log.createdByEmail ?? '—'}  uid: ${log.createdByUid ?? '—'}');
    if ((log.templateId ?? '').isNotEmpty) {
      buf.writeln('Template: ${log.templateId}');
    }
    buf.writeln('Provider message id: ${log.providerMessageId ?? '—'}');
    buf.writeln('');
    if ((log.subject ?? '').isNotEmpty) {
      buf.writeln('Subject:');
      buf.writeln(log.subject);
      buf.writeln('');
    }
    buf.writeln('Preview / body snippet:');
    buf.writeln(log.previewText?.isNotEmpty == true ? log.previewText! : log.message);
    return buf.toString();
  }
}

class _MessageLogCard extends StatelessWidget {
  final TenantMessageHistoryModel log;
  final VoidCallback onOpenDetail;

  const _MessageLogCard({
    required this.log,
    required this.onOpenDetail,
  });

  @override
  Widget build(BuildContext context) {
    final timeStr = DateFormat.MMMd().add_jm().format(log.createdAt);
    final channelLabel = log.type.displayName;
    final tenantLine = [
      log.tenantName,
      log.tenantEmail,
      log.tenantPhone,
    ].where((s) => (s ?? '').trim().isNotEmpty).map((s) => s!.trim()).join(' · ');
    final subtitle =
        tenantLine.isEmpty ? 'Tenant: (none on log)' : tenantLine;

    return Card(
      elevation: 0,
      color: Colors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(color: Colors.grey.shade300),
      ),
      child: InkWell(
        onTap: onOpenDetail,
        borderRadius: BorderRadius.circular(10),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    log.channel == 'sms' ? Icons.sms_outlined : Icons.email_outlined,
                    size: 18,
                    color: AppTheme.primaryBlue,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      log.facilityId,
                      style: const TextStyle(
                        fontWeight: FontWeight.w600,
                        fontSize: 14,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  Text(
                    timeStr,
                    style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                '$channelLabel · ${log.source} · ${log.status.displayName}',
                style: TextStyle(fontSize: 12, color: Colors.grey.shade700),
              ),
              Text(
                subtitle,
                style: TextStyle(fontSize: 12, color: Colors.grey.shade800),
              ),
              const SizedBox(height: 8),
              Text(
                (log.subject?.isNotEmpty == true)
                    ? log.subject!
                    : (log.message.isNotEmpty ? log.message : '(no preview)'),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 13),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
