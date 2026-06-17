import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:sfcapp/models/tenant_message_history_model.dart';
import 'package:sfcapp/services/super_admin_data_service.dart';
import 'package:sfcapp/theme/app_theme.dart';
import 'package:sfcapp/utils/firestore_index_error.dart';
import 'package:sfcapp/widgets/firestore_index_building_panel.dart';

/// Super-admin view of outbound email/SMS audit rows (`facilities/*/messageLogs`).
class MessageLogsTab extends ConsumerStatefulWidget {
  const MessageLogsTab({super.key});

  @override
  ConsumerState<MessageLogsTab> createState() => _MessageLogsTabState();
}

class _MessageLogsTabState extends ConsumerState<MessageLogsTab> {
  String _search = '';
  String? _selectedFacilityId;
  int _streamGeneration = 0;
  Timer? _indexRetryTimer;

  @override
  void dispose() {
    _indexRetryTimer?.cancel();
    super.dispose();
  }

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

  String _facilityLabel(Map<String, String> facilityNames, String facilityId) {
    final name = facilityNames[facilityId];
    return (name != null && name.isNotEmpty) ? name : facilityId;
  }

  List<TenantMessageHistoryModel> _filter(
    List<TenantMessageHistoryModel> all,
    Map<String, String> facilityNames,
  ) {
    var result = all;

    if (_selectedFacilityId != null) {
      result = result
          .where((r) => r.facilityId == _selectedFacilityId)
          .toList();
    }

    final q = _search.trim().toLowerCase();
    if (q.isEmpty) return result;

    return result.where((r) {
      final facilityName = facilityNames[r.facilityId];
      return r.facilityId.toLowerCase().contains(q) ||
          (facilityName?.toLowerCase().contains(q) ?? false) ||
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

  List<String> _facilityIdsInLogs(
    List<TenantMessageHistoryModel> logs,
    Map<String, String> facilityNames,
  ) {
    final ids = logs.map((l) => l.facilityId).toSet().toList();
    ids.sort((a, b) {
      final nameA = _facilityLabel(facilityNames, a).toLowerCase();
      final nameB = _facilityLabel(facilityNames, b).toLowerCase();
      return nameA.compareTo(nameB);
    });
    return ids;
  }

  List<_FacilityLogGroup> _groupByFacility(
    List<TenantMessageHistoryModel> logs,
    Map<String, String> facilityNames,
  ) {
    final grouped = <String, List<TenantMessageHistoryModel>>{};
    for (final log in logs) {
      grouped.putIfAbsent(log.facilityId, () => []).add(log);
    }

    final groups = grouped.entries.map((entry) {
      final sorted = List<TenantMessageHistoryModel>.from(entry.value)
        ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
      return _FacilityLogGroup(
        facilityId: entry.key,
        facilityName: _facilityLabel(facilityNames, entry.key),
        logs: sorted,
        latestAt: sorted.first.createdAt,
      );
    }).toList();

    groups.sort((a, b) => b.latestAt.compareTo(a.latestAt));
    return groups;
  }

  @override
  Widget build(BuildContext context) {
    final facilityNames = ref.watch(allFacilitiesProvider).whenOrNull(
              data: (facilities) => {
                for (final f in facilities) f.id: f.name,
              },
            ) ??
        const <String, String>{};

    return StreamBuilder<List<TenantMessageHistoryModel>>(
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
              collectionGroup: 'messageLogs',
              onRetry: _retryStream,
            );
          }
          _clearIndexRetry();
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Text(
                'Could not load message logs.\n\n$error',
                textAlign: TextAlign.center,
              ),
            ),
          );
        }
        _clearIndexRetry();
        final all = snap.data ?? [];
        final filtered = _filter(all, facilityNames);
        final facilityIdsInLogs = _facilityIdsInLogs(all, facilityNames);
        final showGrouped = _selectedFacilityId == null;

        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _toolbar(
              total: all.length,
              shown: filtered.length,
              facilityIdsInLogs: facilityIdsInLogs,
              facilityNames: facilityNames,
            ),
            Expanded(
              child: filtered.isEmpty
                  ? Center(
                      child: Text(
                        _search.isNotEmpty || _selectedFacilityId != null
                            ? 'No entries match your filters.'
                            : 'No message logs yet.',
                        style: TextStyle(color: Colors.grey.shade600),
                      ),
                    )
                  : showGrouped
                      ? _buildGroupedList(filtered, facilityNames)
                      : _buildFlatList(filtered, facilityNames),
            ),
          ],
        );
      },
    );
  }

  Widget _buildFlatList(
    List<TenantMessageHistoryModel> logs,
    Map<String, String> facilityNames,
  ) {
    return ListView.separated(
      padding: const EdgeInsets.all(16),
      itemCount: logs.length,
      separatorBuilder: (_, __) => const SizedBox(height: 10),
      itemBuilder: (context, i) => _MessageLogCard(
        log: logs[i],
        facilityName: _facilityLabel(facilityNames, logs[i].facilityId),
        showFacilityHeader: true,
        onOpenDetail: () => _openDetail(logs[i], facilityNames),
      ),
    );
  }

  Widget _buildGroupedList(
    List<TenantMessageHistoryModel> logs,
    Map<String, String> facilityNames,
  ) {
    final groups = _groupByFacility(logs, facilityNames);

    return ListView.separated(
      padding: const EdgeInsets.all(16),
      itemCount: groups.length,
      separatorBuilder: (_, __) => const SizedBox(height: 10),
      itemBuilder: (context, i) {
        final group = groups[i];
        final latestStr = DateFormat.MMMd().add_jm().format(group.latestAt);

        return Container(
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: Colors.grey.shade300),
          ),
          child: ExpansionTile(
            initiallyExpanded: i == 0,
            tilePadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
            leading: CircleAvatar(
              backgroundColor: AppTheme.primaryBlue.withValues(alpha: 0.1),
              radius: 18,
              child: const Icon(
                Icons.business,
                size: 18,
                color: AppTheme.primaryBlue,
              ),
            ),
            title: Text(
              group.facilityName,
              style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            subtitle: Text(
              '${group.logs.length} message${group.logs.length == 1 ? '' : 's'} · latest $latestStr',
              style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
            ),
            children: [
              for (var j = 0; j < group.logs.length; j++) ...[
                if (j > 0) const SizedBox(height: 8),
                _MessageLogCard(
                  log: group.logs[j],
                  facilityName: group.facilityName,
                  showFacilityHeader: false,
                  onOpenDetail: () => _openDetail(group.logs[j], facilityNames),
                ),
              ],
            ],
          ),
        );
      },
    );
  }

  Widget _toolbar({
    required int total,
    required int shown,
    required List<String> facilityIdsInLogs,
    required Map<String, String> facilityNames,
  }) {
    return Material(
      color: Colors.white,
      elevation: 1,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
        child: Row(
          children: [
            Expanded(
              flex: 3,
              child: TextField(
                decoration: const InputDecoration(
                  hintText:
                      'Search facility, tenant, subject, preview, provider id…',
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
            DropdownButton<String?>(
              value: _selectedFacilityId,
              hint: const Text('All facilities'),
              items: [
                const DropdownMenuItem<String?>(
                  value: null,
                  child: Text('All facilities'),
                ),
                ...facilityIdsInLogs.map(
                  (id) => DropdownMenuItem<String?>(
                    value: id,
                    child: SizedBox(
                      width: 180,
                      child: Text(
                        _facilityLabel(facilityNames, id),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ),
                ),
              ],
              onChanged: (v) => setState(() => _selectedFacilityId = v),
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

  void _openDetail(
    TenantMessageHistoryModel log,
    Map<String, String> facilityNames,
  ) {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Message log detail'),
        content: SizedBox(
          width: 560,
          child: SingleChildScrollView(
            child: SelectableText(
              _detailText(log, facilityNames),
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

  String _detailText(
    TenantMessageHistoryModel log,
    Map<String, String> facilityNames,
  ) {
    final facilityName = _facilityLabel(facilityNames, log.facilityId);
    final buf = StringBuffer();
    buf.writeln(
        'Created: ${DateFormat.yMMMd().add_jm().format(log.createdAt)}');
    if (log.sentAt != log.createdAt) {
      buf.writeln('Sent: ${DateFormat.yMMMd().add_jm().format(log.sentAt)}');
    }
    buf.writeln('Facility: $facilityName (${log.facilityId})');
    buf.writeln(
        'Channel: ${log.channel}  direction: ${log.direction}  source: ${log.source}');
    buf.writeln('Status: ${log.status.displayName}  provider: ${log.provider}');
    if ((log.errorCode ?? '').isNotEmpty ||
        (log.errorMessage ?? '').isNotEmpty) {
      buf.writeln('Error: ${log.errorCode ?? '—'}  ${log.errorMessage ?? ''}');
    }
    buf.writeln(
        'Tenant: ${log.tenantName ?? '—'}  id: ${log.tenantId ?? '—'}');
    buf.writeln(
        'Email: ${log.tenantEmail ?? '—'}  Phone: ${log.tenantPhone ?? '—'}');
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
    buf.writeln(
        log.previewText?.isNotEmpty == true ? log.previewText! : log.message);
    return buf.toString();
  }
}

class _FacilityLogGroup {
  final String facilityId;
  final String facilityName;
  final List<TenantMessageHistoryModel> logs;
  final DateTime latestAt;

  const _FacilityLogGroup({
    required this.facilityId,
    required this.facilityName,
    required this.logs,
    required this.latestAt,
  });
}

class _MessageLogCard extends StatelessWidget {
  final TenantMessageHistoryModel log;
  final String facilityName;
  final bool showFacilityHeader;
  final VoidCallback onOpenDetail;

  const _MessageLogCard({
    required this.log,
    required this.facilityName,
    required this.showFacilityHeader,
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
    ]
        .where((s) => (s ?? '').trim().isNotEmpty)
        .map((s) => s!.trim())
        .join(' · ');
    final subtitle =
        tenantLine.isEmpty ? 'Tenant: (none on log)' : tenantLine;
    final hasResolvedName = facilityName != log.facilityId;

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
              if (showFacilityHeader) ...[
                Row(
                  children: [
                    Icon(
                      log.channel == 'sms'
                          ? Icons.sms_outlined
                          : Icons.email_outlined,
                      size: 18,
                      color: AppTheme.primaryBlue,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        facilityName,
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
                      style:
                          TextStyle(fontSize: 12, color: Colors.grey.shade600),
                    ),
                  ],
                ),
                if (hasResolvedName) ...[
                  const SizedBox(height: 2),
                  Padding(
                    padding: const EdgeInsets.only(left: 26),
                    child: Text(
                      log.facilityId,
                      style: TextStyle(fontSize: 11, color: Colors.grey.shade500),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
                const SizedBox(height: 6),
              ] else ...[
                Row(
                  children: [
                    Icon(
                      log.channel == 'sms'
                          ? Icons.sms_outlined
                          : Icons.email_outlined,
                      size: 18,
                      color: AppTheme.primaryBlue,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        '$channelLabel · ${log.source} · ${log.status.displayName}',
                        style:
                            TextStyle(fontSize: 12, color: Colors.grey.shade700),
                      ),
                    ),
                    Text(
                      timeStr,
                      style:
                          TextStyle(fontSize: 12, color: Colors.grey.shade600),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
              ],
              if (showFacilityHeader)
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
