import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:sfcapp/models/super_admin_ai_chat_log.dart';
import 'package:sfcapp/theme/app_theme.dart';
import 'package:sfcapp/utils/firestore_index_error.dart';
import 'package:sfcapp/widgets/firestore_index_building_panel.dart';

/// Super-admin review of AI assistant turns (user + assistant), with facility and user identity.
class AiLogsTab extends StatefulWidget {
  const AiLogsTab({super.key});

  @override
  State<AiLogsTab> createState() => _AiLogsTabState();
}

class _AiLogsTabState extends State<AiLogsTab> {
  String _search = '';
  int _streamGeneration = 0;
  Timer? _indexRetryTimer;

  @override
  void dispose() {
    _indexRetryTimer?.cancel();
    super.dispose();
  }

  Stream<List<SuperAdminAiChatLog>> get _stream {
    return FirebaseFirestore.instance
        .collectionGroup('aiChatAuditLogs')
        .orderBy('createdAt', descending: true)
        .limit(400)
        .snapshots()
        .map((snap) =>
            snap.docs.map((d) => SuperAdminAiChatLog.fromFirestore(d)).toList());
  }

  void _retryStream() {
    setState(() => _streamGeneration++);
  }

  void _scheduleIndexRetry() {
    _indexRetryTimer ??= Timer.periodic(const Duration(seconds: 20), (_) {
      if (mounted) _retryStream();
    });
  }

  void _clearIndexRetry() {
    _indexRetryTimer?.cancel();
    _indexRetryTimer = null;
  }

  List<SuperAdminAiChatLog> _filter(List<SuperAdminAiChatLog> all) {
    final q = _search.trim().toLowerCase();
    if (q.isEmpty) return all;
    return all.where((r) {
      return r.facilityId.toLowerCase().contains(q) ||
          (r.facilityName?.toLowerCase().contains(q) ?? false) ||
          (r.userEmail?.toLowerCase().contains(q) ?? false) ||
          r.userId.toLowerCase().contains(q) ||
          r.userMessage.toLowerCase().contains(q) ||
          r.assistantReply.toLowerCase().contains(q) ||
          r.requestId.toLowerCase().contains(q);
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<SuperAdminAiChatLog>>(
      key: ValueKey(_streamGeneration),
      stream: _stream,
      builder: (context, snap) {
        if (snap.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snap.hasError) {
          final error = snap.error!;
          if (isFirestoreIndexBuildingError(error)) {
            _scheduleIndexRetry();
            return FirestoreIndexBuildingPanel(
              collectionGroup: 'aiChatAuditLogs',
              onRetry: _retryStream,
            );
          }
          _clearIndexRetry();
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Text(
                'Could not load AI logs.\n\n$error',
                textAlign: TextAlign.center,
              ),
            ),
          );
        }
        _clearIndexRetry();
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
                            : 'No AI audit entries yet. New chats are logged after you deploy updated AI functions.',
                        style: TextStyle(color: Colors.grey.shade600),
                      ),
                    )
                  : ListView.separated(
                      padding: const EdgeInsets.all(16),
                      itemCount: filtered.length,
                      separatorBuilder: (_, __) => const SizedBox(height: 10),
                      itemBuilder: (context, i) =>
                          _AiLogCard(log: filtered[i], onOpenDetail: () => _openDetail(filtered[i])),
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
                  hintText: 'Search facility, user email, uid, message…',
                  prefixIcon: Icon(Icons.search, size: 20),
                  isDense: true,
                  border: OutlineInputBorder(),
                  contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 10),
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

  void _openDetail(SuperAdminAiChatLog log) {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('AI turn detail'),
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
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Close')),
        ],
      ),
    );
  }

  String _detailText(SuperAdminAiChatLog log) {
    final buf = StringBuffer();
    buf.writeln(
        'Time: ${log.createdAt != null ? DateFormat.yMMMd().add_jm().format(log.createdAt!) : '—'}');
    buf.writeln('Facility: ${log.facilityName ?? '(unknown)'} (${log.facilityId})');
    buf.writeln('User: ${log.userEmail ?? '(no email on token)'}  uid: ${log.userId}');
    buf.writeln('Source: ${log.source}  provider: ${log.providerUsed}  model: ${log.model}');
    buf.writeln(
        'Tokens: ${log.tokensUsed}  latency: ${log.latencyMs}ms  requestId: ${log.requestId}');
    buf.writeln('');
    buf.writeln('— User message —');
    buf.writeln(log.userMessage);
    buf.writeln('');
    buf.writeln('— Assistant reply —');
    buf.writeln(log.assistantReply);
    return buf.toString();
  }
}

class _AiLogCard extends StatelessWidget {
  final SuperAdminAiChatLog log;
  final VoidCallback onOpenDetail;

  const _AiLogCard({required this.log, required this.onOpenDetail});

  @override
  Widget build(BuildContext context) {
    final timeStr = log.createdAt != null
        ? DateFormat.MMMd().add_jm().format(log.createdAt!)
        : '—';
    final who = (log.userEmail ?? '').isNotEmpty
        ? log.userEmail!
        : 'uid ${log.userId.length > 10 ? '${log.userId.substring(0, 8)}…' : log.userId}';

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
                  Icon(Icons.smart_toy_outlined, size: 18, color: AppTheme.primaryBlue),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      (log.facilityName ?? '').isNotEmpty
                          ? log.facilityName!
                          : log.facilityId,
                      style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  Text(timeStr, style: TextStyle(fontSize: 12, color: Colors.grey.shade600)),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                who,
                style: TextStyle(fontSize: 12, color: Colors.grey.shade800),
              ),
              Text(
                '${log.source} · ${log.model.isNotEmpty ? log.model : log.providerUsed}',
                style: TextStyle(fontSize: 11, color: Colors.grey.shade600),
              ),
              const SizedBox(height: 8),
              Text(
                log.userMessage,
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
