import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:sfcapp/models/bug_report_model.dart';
import 'package:sfcapp/theme/app_theme.dart';

class BugReportsTab extends StatefulWidget {
  const BugReportsTab({super.key});

  @override
  State<BugReportsTab> createState() => _BugReportsTabState();
}

class _BugReportsTabState extends State<BugReportsTab> {
  String _statusFilter = 'all';
  String _severityFilter = 'all';
  String _search = '';

  Stream<List<BugReportModel>> get _stream {
    Query query = FirebaseFirestore.instance
        .collection('bug_reports')
        .orderBy('createdAt', descending: true);
    return query.snapshots().map(
          (snap) => snap.docs.map(BugReportModel.fromFirestore).toList(),
        );
  }

  List<BugReportModel> _filter(List<BugReportModel> all) {
    return all.where((r) {
      final matchStatus =
          _statusFilter == 'all' || r.status.name == _statusFilter;
      final matchSeverity =
          _severityFilter == 'all' || r.severity.name == _severityFilter;
      final q = _search.toLowerCase();
      final matchSearch = q.isEmpty ||
          r.title.toLowerCase().contains(q) ||
          r.description.toLowerCase().contains(q) ||
          r.submittedByEmail.toLowerCase().contains(q) ||
          (r.facilityName?.toLowerCase().contains(q) ?? false);
      return matchStatus && matchSeverity && matchSearch;
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<BugReportModel>>(
      stream: _stream,
      builder: (context, snap) {
        if (snap.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snap.hasError) {
          return Center(child: Text('Error: ${snap.error}'));
        }
        final all = snap.data ?? [];
        final filtered = _filter(all);

        return Column(
          children: [
            _buildToolbar(all, filtered),
            Expanded(
              child: filtered.isEmpty
                  ? _buildEmpty()
                  : ListView.separated(
                      padding: const EdgeInsets.all(16),
                      itemCount: filtered.length,
                      separatorBuilder: (_, __) => const SizedBox(height: 8),
                      itemBuilder: (context, i) =>
                          _BugReportCard(report: filtered[i]),
                    ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildEmpty() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.bug_report_outlined,
              size: 48, color: Colors.grey.shade400),
          const SizedBox(height: 12),
          Text(
            _search.isNotEmpty || _statusFilter != 'all' || _severityFilter != 'all'
                ? 'No reports match your filters.'
                : 'No bug reports yet.',
            style: TextStyle(color: Colors.grey.shade600),
          ),
        ],
      ),
    );
  }

  Widget _buildToolbar(List<BugReportModel> all, List<BugReportModel> filtered) {
    final openCount = all.where((r) => r.status == BugReportStatus.open).length;
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              _StatChip(label: 'Total', count: all.length, color: AppTheme.primaryBlue),
              const SizedBox(width: 8),
              _StatChip(label: 'Open', count: openCount, color: AppTheme.error),
              const SizedBox(width: 8),
              _StatChip(
                  label: 'Resolved',
                  count: all.where((r) => r.status == BugReportStatus.resolved).length,
                  color: AppTheme.success),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: TextField(
                  decoration: InputDecoration(
                    hintText: 'Search title, description, email…',
                    prefixIcon: const Icon(Icons.search, size: 18),
                    isDense: true,
                    border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8)),
                    contentPadding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 10),
                  ),
                  onChanged: (v) => setState(() => _search = v),
                ),
              ),
              const SizedBox(width: 12),
              _buildDropdown<String>(
                value: _statusFilter,
                items: const {
                  'all': 'All Status',
                  'open': 'Open',
                  'inProgress': 'In Progress',
                  'resolved': 'Resolved',
                  'closed': 'Closed',
                },
                onChanged: (v) => setState(() => _statusFilter = v!),
              ),
              const SizedBox(width: 8),
              _buildDropdown<String>(
                value: _severityFilter,
                items: const {
                  'all': 'All Severity',
                  'critical': 'Critical',
                  'high': 'High',
                  'medium': 'Medium',
                  'low': 'Low',
                },
                onChanged: (v) => setState(() => _severityFilter = v!),
              ),
              const SizedBox(width: 12),
              Text('${filtered.length} / ${all.length}',
                  style: Theme.of(context)
                      .textTheme
                      .bodySmall
                      ?.copyWith(color: AppTheme.textSecondary)),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildDropdown<T>({
    required T value,
    required Map<T, String> items,
    required ValueChanged<T?> onChanged,
  }) {
    return DropdownButton<T>(
      value: value,
      isDense: true,
      items: items.entries
          .map((e) => DropdownMenuItem(value: e.key, child: Text(e.value)))
          .toList(),
      onChanged: onChanged,
    );
  }
}

class _StatChip extends StatelessWidget {
  final String label;
  final int count;
  final Color color;

  const _StatChip({required this.label, required this.count, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '$count',
            style: TextStyle(
                fontWeight: FontWeight.w700, color: color, fontSize: 14),
          ),
          const SizedBox(width: 4),
          Text(label,
              style: TextStyle(fontSize: 12, color: color.withValues(alpha: 0.8))),
        ],
      ),
    );
  }
}

class _BugReportCard extends StatefulWidget {
  final BugReportModel report;
  const _BugReportCard({required this.report});

  @override
  State<_BugReportCard> createState() => _BugReportCardState();
}

class _BugReportCardState extends State<_BugReportCard> {
  bool _expanded = false;
  bool _saving = false;
  bool _deleting = false;
  late BugReportStatus _status;
  final _notesCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    _status = widget.report.status;
    _notesCtrl.text = widget.report.adminNotes ?? '';
  }

  @override
  void dispose() {
    _notesCtrl.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      await FirebaseFirestore.instance
          .collection('bug_reports')
          .doc(widget.report.id)
          .update({
        'status': _status.name,
        'adminNotes': _notesCtrl.text.trim(),
        'updatedAt': Timestamp.fromDate(DateTime.now()),
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text('Report updated'),
              duration: Duration(seconds: 2)),
        );
        setState(() => _expanded = false);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e'), backgroundColor: AppTheme.error),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  bool get _canDelete =>
      _status == BugReportStatus.resolved || _status == BugReportStatus.closed;

  Future<void> _confirmAndDelete() async {
    if (!_canDelete) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Set status to Resolved or Closed before deleting this report.',
          ),
        ),
      );
      return;
    }
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete bug report?'),
        content: Text(
          'Permanently remove “${widget.report.title}” from bug_reports? '
          'This cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppTheme.error),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;

    setState(() => _deleting = true);
    try {
      await FirebaseFirestore.instance
          .collection('bug_reports')
          .doc(widget.report.id)
          .delete();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Bug report deleted'),
            backgroundColor: AppTheme.success,
          ),
        );
        setState(() => _expanded = false);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Delete failed: $e'),
            backgroundColor: AppTheme.error,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _deleting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final report = widget.report;
    final theme = Theme.of(context);
    final fmt = DateFormat('MMM d, yyyy h:mm a');

    return Container(
      decoration: BoxDecoration(
        color: theme.cardColor,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: _severityColor(report.severity).withValues(alpha: 0.35),
          width: 1.5,
        ),
      ),
      child: Column(
        children: [
          InkWell(
            onTap: () => setState(() => _expanded = !_expanded),
            borderRadius: BorderRadius.circular(10),
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _SeverityDot(severity: report.severity),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                report.title,
                                style: theme.textTheme.bodyMedium?.copyWith(
                                    fontWeight: FontWeight.w600),
                              ),
                            ),
                            _StatusBadge(status: report.status),
                          ],
                        ),
                        const SizedBox(height: 4),
                        Text(
                          report.submittedByEmail,
                          style: theme.textTheme.bodySmall
                              ?.copyWith(color: AppTheme.textSecondary),
                        ),
                        if (report.facilityName != null) ...[
                          const SizedBox(height: 2),
                          Row(
                            children: [
                              Icon(Icons.apartment,
                                  size: 12,
                                  color: AppTheme.textSecondary),
                              const SizedBox(width: 4),
                              Text(
                                report.facilityName!,
                                style: theme.textTheme.bodySmall?.copyWith(
                                    color: AppTheme.textSecondary),
                              ),
                            ],
                          ),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text(
                        fmt.format(report.createdAt),
                        style: theme.textTheme.bodySmall
                            ?.copyWith(color: AppTheme.textSecondary, fontSize: 11),
                      ),
                      const SizedBox(height: 4),
                      Icon(
                        _expanded
                            ? Icons.keyboard_arrow_up
                            : Icons.keyboard_arrow_down,
                        size: 18,
                        color: AppTheme.textSecondary,
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          if (_expanded) ...[
            Divider(height: 1, color: theme.dividerColor),
            Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Description',
                      style: theme.textTheme.labelMedium
                          ?.copyWith(fontWeight: FontWeight.w600)),
                  const SizedBox(height: 6),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(report.description,
                        style: theme.textTheme.bodySmall),
                  ),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('Status',
                                style: theme.textTheme.labelMedium
                                    ?.copyWith(fontWeight: FontWeight.w600)),
                            const SizedBox(height: 6),
                            DropdownButtonFormField<BugReportStatus>(
                              value: _status,
                              decoration: InputDecoration(
                                isDense: true,
                                border: OutlineInputBorder(
                                    borderRadius: BorderRadius.circular(8)),
                                contentPadding: const EdgeInsets.symmetric(
                                    horizontal: 12, vertical: 10),
                              ),
                              items: BugReportStatus.values
                                  .map((s) => DropdownMenuItem(
                                        value: s,
                                        child: Text(_statusLabel(s)),
                                      ))
                                  .toList(),
                              onChanged: (v) =>
                                  setState(() => _status = v!),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 16),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('Severity',
                                style: theme.textTheme.labelMedium
                                    ?.copyWith(fontWeight: FontWeight.w600)),
                            const SizedBox(height: 6),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 12, vertical: 10),
                              decoration: BoxDecoration(
                                border: Border.all(
                                    color: theme.dividerColor),
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: Row(
                                children: [
                                  _SeverityDot(severity: report.severity),
                                  const SizedBox(width: 8),
                                  Text(_severityLabel(report.severity),
                                      style: theme.textTheme.bodyMedium),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  Text('Admin Notes',
                      style: theme.textTheme.labelMedium
                          ?.copyWith(fontWeight: FontWeight.w600)),
                  const SizedBox(height: 6),
                  TextField(
                    controller: _notesCtrl,
                    maxLines: 3,
                    decoration: InputDecoration(
                      hintText: 'Internal notes, resolution steps…',
                      border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8)),
                      isDense: true,
                      contentPadding: const EdgeInsets.all(12),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      TextButton.icon(
                        onPressed: (_saving || _deleting) ? null : _confirmAndDelete,
                        icon: _deleting
                            ? const SizedBox(
                                width: 14,
                                height: 14,
                                child: CircularProgressIndicator(strokeWidth: 2),
                              )
                            : const Icon(Icons.delete_outline, size: 18),
                        label: Text(_deleting ? 'Deleting…' : 'Delete report'),
                        style: TextButton.styleFrom(
                          foregroundColor: _canDelete
                              ? AppTheme.error
                              : AppTheme.textTertiary,
                        ),
                      ),
                      const Spacer(),
                      TextButton(
                        onPressed: (_saving || _deleting)
                            ? null
                            : () => setState(() => _expanded = false),
                        child: const Text('Cancel'),
                      ),
                      const SizedBox(width: 8),
                      ElevatedButton.icon(
                        onPressed: (_saving || _deleting) ? null : _save,
                        icon: _saving
                            ? const SizedBox(
                                width: 14,
                                height: 14,
                                child: CircularProgressIndicator(
                                    strokeWidth: 2),
                              )
                            : const Icon(Icons.save, size: 16),
                        label: Text(_saving ? 'Saving…' : 'Save Changes'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  Color _severityColor(BugReportSeverity s) {
    switch (s) {
      case BugReportSeverity.critical:
        return Colors.red;
      case BugReportSeverity.high:
        return Colors.deepOrange;
      case BugReportSeverity.medium:
        return Colors.orange;
      case BugReportSeverity.low:
        return Colors.green;
    }
  }

  String _severityLabel(BugReportSeverity s) {
    switch (s) {
      case BugReportSeverity.critical:
        return 'Critical';
      case BugReportSeverity.high:
        return 'High';
      case BugReportSeverity.medium:
        return 'Medium';
      case BugReportSeverity.low:
        return 'Low';
    }
  }

  String _statusLabel(BugReportStatus s) {
    switch (s) {
      case BugReportStatus.open:
        return 'Open';
      case BugReportStatus.inProgress:
        return 'In Progress';
      case BugReportStatus.resolved:
        return 'Resolved';
      case BugReportStatus.closed:
        return 'Closed';
    }
  }
}

class _SeverityDot extends StatelessWidget {
  final BugReportSeverity severity;
  const _SeverityDot({required this.severity});

  @override
  Widget build(BuildContext context) {
    final color = switch (severity) {
      BugReportSeverity.critical => Colors.red,
      BugReportSeverity.high => Colors.deepOrange,
      BugReportSeverity.medium => Colors.orange,
      BugReportSeverity.low => Colors.green,
    };
    return Container(
      width: 10,
      height: 10,
      margin: const EdgeInsets.only(top: 4),
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
    );
  }
}

class _StatusBadge extends StatelessWidget {
  final BugReportStatus status;
  const _StatusBadge({required this.status});

  @override
  Widget build(BuildContext context) {
    final (label, color) = switch (status) {
      BugReportStatus.open => ('Open', AppTheme.error),
      BugReportStatus.inProgress => ('In Progress', AppTheme.warning),
      BugReportStatus.resolved => ('Resolved', AppTheme.success),
      BugReportStatus.closed => ('Closed', AppTheme.textSecondary),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Text(
        label,
        style: TextStyle(
            fontSize: 11, fontWeight: FontWeight.w600, color: color),
      ),
    );
  }
}
