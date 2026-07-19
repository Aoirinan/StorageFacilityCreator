import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:sfcapp/models/dnr_model.dart';
import 'package:sfcapp/models/global_dnr_model.dart';
import 'package:sfcapp/services/dnr_service.dart';
import 'package:sfcapp/services/global_dnr_service.dart';
import 'package:sfcapp/theme/app_theme.dart';

/// Super-admin moderation of ALL Do Not Rent entries (facility-scoped lists
/// across every facility + the platform-wide global list). Supports
/// deactivating and permanently deleting any entry, per the published
/// Do Not Rent Data Policy (SFC may deactivate or remove any entry).
class DnrModerationTab extends StatefulWidget {
  const DnrModerationTab({super.key});

  @override
  State<DnrModerationTab> createState() => _DnrModerationTabState();
}

/// Unified row over facility-scoped and global entries.
class _DnrRow {
  final bool isGlobal;
  final String id;
  final String name;
  final String email;
  final String phone;
  final String reason;
  final bool active;
  final DateTime? createdAt;
  final String sourceLabel;
  final String? facilityId; // for facility-scoped entries

  _DnrRow.fromFacility(DNRModel m)
      : isGlobal = false,
        id = m.id,
        name = m.name,
        email = m.email,
        phone = m.phone,
        reason = m.reason,
        active = m.active,
        createdAt = m.addedAt,
        sourceLabel = m.facilityName ?? m.facilityId,
        facilityId = m.facilityId;

  _DnrRow.fromGlobal(GlobalDNREntryModel m)
      : isGlobal = true,
        id = m.id,
        name = m.fullName,
        email = m.email,
        phone = m.phone,
        reason = m.reason,
        active = m.isActive,
        createdAt = m.createdAt,
        sourceLabel =
            'Global · ${m.createdByFacilityName ?? m.createdByFacilityId}',
        facilityId = null;
}

class _DnrModerationTabState extends State<DnrModerationTab> {
  String _search = '';
  bool _isBusy = false;
  late Future<List<_DnrRow>> _future;

  @override
  void initState() {
    super.initState();
    _future = _loadAll();
  }

  Future<List<_DnrRow>> _loadAll() async {
    final rows = <_DnrRow>[];

    // Facility-scoped entries across ALL facilities (superadmin collection-group read).
    final facilitySnap =
        await FirebaseFirestore.instance.collectionGroup('dnr').limit(1000).get();
    for (final doc in facilitySnap.docs) {
      try {
        rows.add(_DnrRow.fromFacility(DNRModel.fromFirestore(doc)));
      } catch (_) {
        // Skip malformed rows rather than breaking moderation.
      }
    }

    // Platform-wide global entries (all statuses).
    final globals = await GlobalDNRService.getGlobalDNREntries(limit: 1000);
    rows.addAll(globals.map(_DnrRow.fromGlobal));

    rows.sort((a, b) {
      final at = a.createdAt ?? DateTime.fromMillisecondsSinceEpoch(0);
      final bt = b.createdAt ?? DateTime.fromMillisecondsSinceEpoch(0);
      return bt.compareTo(at);
    });
    return rows;
  }

  void _refresh() {
    setState(() => _future = _loadAll());
  }

  List<_DnrRow> _filter(List<_DnrRow> all) {
    final q = _search.trim().toLowerCase();
    if (q.isEmpty) return all;
    return all.where((r) {
      return r.name.toLowerCase().contains(q) ||
          r.email.toLowerCase().contains(q) ||
          r.phone.toLowerCase().contains(q) ||
          r.reason.toLowerCase().contains(q) ||
          r.sourceLabel.toLowerCase().contains(q);
    }).toList();
  }

  Future<void> _setActive(_DnrRow row, bool active) async {
    setState(() => _isBusy = true);
    try {
      if (row.isGlobal) {
        await GlobalDNRService.updateGlobalDNREntry(
          entryId: row.id,
          status: active ? GlobalDnrStatus.active : GlobalDnrStatus.inactive,
        );
      } else {
        await DNRService.toggleDNRActive(
          facilityId: row.facilityId!,
          dnrId: row.id,
          active: active,
        );
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(
              '"${row.name}" ${active ? 'reactivated' : 'deactivated'}'),
        ));
      }
      _refresh();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Error updating entry: $e'),
          backgroundColor: AppTheme.error,
        ));
      }
    } finally {
      if (mounted) setState(() => _isBusy = false);
    }
  }

  Future<void> _delete(_DnrRow row) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Permanently delete DNR entry'),
        content: Text(
            'Permanently delete "${row.name}" from the ${row.isGlobal ? 'GLOBAL' : 'facility'} '
            'DNR list?\n\nSource: ${row.sourceLabel}\nReason: ${row.reason}\n\n'
            'This removes the entry (and any evidence for global entries) and cannot be undone.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(backgroundColor: AppTheme.error),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    setState(() => _isBusy = true);
    try {
      if (row.isGlobal) {
        await GlobalDNRService.deleteGlobalDNREntry(row.id);
      } else {
        await DNRService.deleteDNREntry(
          facilityId: row.facilityId!,
          dnrId: row.id,
        );
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('"${row.name}" deleted')),
        );
      }
      _refresh();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Error deleting entry: $e'),
          backgroundColor: AppTheme.error,
        ));
      }
    } finally {
      if (mounted) setState(() => _isBusy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<_DnrRow>>(
      future: _future,
      builder: (context, snap) {
        if (snap.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snap.hasError) {
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text('Could not load DNR entries.\n\n${snap.error}',
                      textAlign: TextAlign.center),
                  const SizedBox(height: 16),
                  ElevatedButton(
                      onPressed: _refresh, child: const Text('Retry')),
                ],
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
            if (_isBusy) const LinearProgressIndicator(minHeight: 2),
            Expanded(
              child: filtered.isEmpty
                  ? Center(
                      child: Text(
                        _search.isNotEmpty
                            ? 'No entries match your search.'
                            : 'No DNR entries on the platform.',
                        style: TextStyle(color: Colors.grey.shade600),
                      ),
                    )
                  : ListView.separated(
                      padding: const EdgeInsets.all(16),
                      itemCount: filtered.length,
                      separatorBuilder: (_, __) => const SizedBox(height: 10),
                      itemBuilder: (context, i) => _card(filtered[i]),
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
                  hintText: 'Search name, email, phone, reason, facility…',
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
            Text('$shown / $total',
                style: TextStyle(color: Colors.grey.shade700, fontSize: 13)),
            const SizedBox(width: 12),
            IconButton(
              tooltip: 'Refresh',
              onPressed: _refresh,
              icon: const Icon(Icons.refresh),
            ),
          ],
        ),
      ),
    );
  }

  Widget _card(_DnrRow row) {
    final timeStr = row.createdAt != null
        ? DateFormat.yMMMd().add_jm().format(row.createdAt!)
        : '—';

    return Card(
      elevation: 0,
      color: Colors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(color: Colors.grey.shade300),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  row.isGlobal ? Icons.public : Icons.business,
                  size: 18,
                  color: row.isGlobal ? AppTheme.error : AppTheme.primaryBlue,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    row.name,
                    style: const TextStyle(
                        fontWeight: FontWeight.w600, fontSize: 14),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                Chip(
                  label: Text(row.active ? 'active' : 'inactive',
                      style: const TextStyle(fontSize: 11)),
                  backgroundColor: row.active
                      ? AppTheme.success.withValues(alpha: 0.15)
                      : Colors.grey.shade200,
                  visualDensity: VisualDensity.compact,
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(row.sourceLabel,
                style: TextStyle(fontSize: 12, color: Colors.grey.shade800)),
            Text('${row.email} · ${row.phone} · $timeStr',
                style: TextStyle(fontSize: 12, color: Colors.grey.shade600)),
            const SizedBox(height: 6),
            Text(row.reason,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 13)),
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton.icon(
                  onPressed:
                      _isBusy ? null : () => _setActive(row, !row.active),
                  icon: Icon(row.active ? Icons.pause_circle : Icons.play_circle,
                      size: 18),
                  label: Text(row.active ? 'Deactivate' : 'Reactivate'),
                ),
                const SizedBox(width: 8),
                TextButton.icon(
                  onPressed: _isBusy ? null : () => _delete(row),
                  icon: const Icon(Icons.delete_forever,
                      size: 18, color: AppTheme.error),
                  label: const Text('Delete',
                      style: TextStyle(color: AppTheme.error)),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
