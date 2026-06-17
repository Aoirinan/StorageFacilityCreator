import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:sfcapp/services/super_admin_data_service.dart';
import 'package:sfcapp/services/superadmin_service.dart';
import 'package:sfcapp/theme/app_theme.dart';

class LeadsTab extends ConsumerStatefulWidget {
  const LeadsTab({super.key});

  @override
  ConsumerState<LeadsTab> createState() => _LeadsTabState();
}

class _LeadsTabState extends ConsumerState<LeadsTab> {
  String _search = '';
  String _statusFilter = 'all';
  bool _staleOnly = false;
  int _staleHours = 24;

  @override
  Widget build(BuildContext context) {
    final leadsAsync = ref.watch(marketingLeadsProvider);

    return leadsAsync.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(child: Text('Error: $e')),
      data: (leads) {
        final filtered = leads.where((lead) {
          final q = _search.toLowerCase();
          final matchesSearch = q.isEmpty ||
              lead.name.toLowerCase().contains(q) ||
              lead.email.toLowerCase().contains(q) ||
              lead.facilityName.toLowerCase().contains(q) ||
              (lead.phone ?? '').toLowerCase().contains(q);
          final matchesStatus =
              _statusFilter == 'all' || lead.status.value == _statusFilter;
          final stale = _isStaleLead(lead, _staleHours);
          final matchesStale = !_staleOnly || stale;
          return matchesSearch && matchesStatus && matchesStale;
        }).toList();
        final staleCount = leads.where((lead) => _isStaleLead(lead, _staleHours)).length;

        return Column(
          children: [
            _buildToolbar(filtered.length, leads.length, staleCount),
            Expanded(
              child: filtered.isEmpty
                  ? const Center(child: Text('No leads match your filters.'))
                  : ListView.separated(
                      padding: const EdgeInsets.all(16),
                      itemCount: filtered.length,
                      separatorBuilder: (_, __) => const SizedBox(height: 8),
                      itemBuilder: (context, i) =>
                          _LeadRow(lead: filtered[i], staleHours: _staleHours),
                    ),
            ),
          ],
        );
      },
    );
  }

  bool _isStaleLead(MarketingLead lead, int thresholdHours) {
    final createdAt = lead.createdAt;
    if (createdAt == null) return false;
    if (lead.status != MarketingLeadStatus.newLead) return false;
    if (lead.firstContactedAt != null) return false;
    final diff = DateTime.now().difference(createdAt);
    return diff.inHours >= thresholdHours;
  }

  Widget _buildToolbar(int shown, int total, int staleCount) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              decoration: InputDecoration(
                hintText: 'Search by name, email, phone, facility...',
                prefixIcon: const Icon(Icons.search, size: 18),
                isDense: true,
                border:
                    OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              ),
              onChanged: (v) => setState(() => _search = v),
            ),
          ),
          const SizedBox(width: 12),
          DropdownButton<String>(
            value: _statusFilter,
            items: const [
              DropdownMenuItem(value: 'all', child: Text('All')),
              DropdownMenuItem(value: 'new', child: Text('New')),
              DropdownMenuItem(value: 'contacted', child: Text('Contacted')),
              DropdownMenuItem(value: 'qualified', child: Text('Qualified')),
              DropdownMenuItem(value: 'won', child: Text('Won')),
              DropdownMenuItem(value: 'lost', child: Text('Lost')),
            ],
            onChanged: (v) => setState(() => _statusFilter = v ?? 'all'),
          ),
          const SizedBox(width: 12),
          FilterChip(
            label: Text('Stale ($_staleHours+h): $staleCount'),
            selected: _staleOnly,
            onSelected: (value) => setState(() => _staleOnly = value),
          ),
          const SizedBox(width: 8),
          DropdownButton<int>(
            value: _staleHours,
            items: const [
              DropdownMenuItem(value: 6, child: Text('6h')),
              DropdownMenuItem(value: 12, child: Text('12h')),
              DropdownMenuItem(value: 24, child: Text('24h')),
              DropdownMenuItem(value: 48, child: Text('48h')),
            ],
            onChanged: (v) => setState(() => _staleHours = v ?? 24),
          ),
          const SizedBox(width: 12),
          Text(
            '$shown / $total',
            style: Theme.of(context)
                .textTheme
                .bodySmall
                ?.copyWith(color: AppTheme.textSecondary),
          ),
        ],
      ),
    );
  }
}

class _LeadRow extends StatefulWidget {
  const _LeadRow({required this.lead, required this.staleHours});

  final MarketingLead lead;
  final int staleHours;

  @override
  State<_LeadRow> createState() => _LeadRowState();
}

class _LeadRowState extends State<_LeadRow> {
  bool _saving = false;
  bool _deleting = false;

  String get _actorUid => FirebaseAuth.instance.currentUser?.uid ?? 'unknown';
  String get _actorEmail => FirebaseAuth.instance.currentUser?.email ?? 'unknown';
  String get _actorName {
    final email = _actorEmail;
    if (email == 'unknown' || !email.contains('@')) return 'Unknown User';
    return email.split('@').first;
  }

  Color _statusColor(MarketingLeadStatus status) {
    switch (status) {
      case MarketingLeadStatus.newLead:
        return AppTheme.info;
      case MarketingLeadStatus.contacted:
        return Colors.indigo;
      case MarketingLeadStatus.qualified:
        return AppTheme.warning;
      case MarketingLeadStatus.won:
        return AppTheme.success;
      case MarketingLeadStatus.lost:
        return AppTheme.error;
    }
  }

  String _sourceLabel(String source) {
    switch (source) {
      case 'website_contact':
        return 'Website';
      case 'twilio_inbound_sms':
        return 'Inbound SMS';
      case 'twilio_inbound_call':
        return 'Inbound Call';
      default:
        return source.replaceAll('_', ' ');
    }
  }

  bool _isStaleLead() {
    final createdAt = widget.lead.createdAt;
    if (createdAt == null) return false;
    if (widget.lead.status != MarketingLeadStatus.newLead) return false;
    if (widget.lead.firstContactedAt != null) return false;
    return DateTime.now().difference(createdAt).inHours >= widget.staleHours;
  }

  String _displayNameFromEmail(String email) {
    final local = email.split('@').first.replaceAll('.', ' ').replaceAll('_', ' ');
    return local
        .split(' ')
        .where((part) => part.trim().isNotEmpty)
        .map((part) =>
            '${part[0].toUpperCase()}${part.substring(1).toLowerCase()}')
        .join(' ');
  }

  List<_RepOption> _repOptions() {
    final emails = <String>{
      ...SuperAdminService.superAdminEmails,
      _actorEmail,
      if ((widget.lead.assignedToEmail ?? '').trim().isNotEmpty)
        widget.lead.assignedToEmail!.trim(),
      if ((widget.lead.workedByEmail ?? '').trim().isNotEmpty)
        widget.lead.workedByEmail!.trim(),
    };
    final sorted = emails.where((e) => e.contains('@')).toList()..sort();
    final reps = sorted
        .map((email) => _RepOption(
              email: email,
              name: _displayNameFromEmail(email),
            ))
        .toList();
    if (reps.isEmpty) {
      reps.add(const _RepOption(name: 'Unknown User', email: 'unknown@example.com'));
    }
    return reps;
  }

  _RepOption _selectedOrActorRep(List<_RepOption> options) {
    final assignedEmail = (widget.lead.assignedToEmail ?? '').trim();
    if (assignedEmail.isNotEmpty) {
      for (final rep in options) {
        if (rep.email.toLowerCase() == assignedEmail.toLowerCase()) return rep;
      }
    }
    for (final rep in options) {
      if (rep.email.toLowerCase() == _actorEmail.toLowerCase()) return rep;
    }
    return options.first;
  }

  Future<void> _recordNote({required bool isCall}) async {
    final noteController = TextEditingController();
    final title = isCall ? 'Log Call' : 'Add Note';
    final reps = _repOptions();
    _RepOption selectedRep = _selectedOrActorRep(reps);
    String callOutcome = 'follow_up_needed';

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: Text(title),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              DropdownButtonFormField<String>(
                initialValue: selectedRep.email,
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'Worked by'),
                items: reps
                    .map(
                      (rep) => DropdownMenuItem(
                        value: rep.email,
                        child: Text(rep.label),
                      ),
                    )
                    .toList(),
                onChanged: (value) {
                  if (value == null) return;
                  setDialogState(() {
                    selectedRep =
                        reps.firstWhere((rep) => rep.email == value);
                  });
                },
              ),
              if (isCall) ...[
                const SizedBox(height: 8),
                DropdownButtonFormField<String>(
                  initialValue: callOutcome,
                  decoration: const InputDecoration(labelText: 'Call outcome'),
                  items: const [
                    DropdownMenuItem(
                        value: 'no_answer', child: Text('No answer')),
                    DropdownMenuItem(
                        value: 'follow_up_needed',
                        child: Text('Follow-up needed')),
                    DropdownMenuItem(
                        value: 'interested', child: Text('Interested')),
                    DropdownMenuItem(
                        value: 'not_interested', child: Text('Not interested')),
                    DropdownMenuItem(
                        value: 'closed_won', child: Text('Closed won')),
                    DropdownMenuItem(
                        value: 'closed_lost', child: Text('Closed lost')),
                  ],
                  onChanged: (value) {
                    if (value == null) return;
                    setDialogState(() => callOutcome = value);
                  },
                ),
              ],
              const SizedBox(height: 8),
              TextField(
                controller: noteController,
                maxLines: 4,
                decoration: InputDecoration(
                  labelText: isCall ? 'Call notes' : 'Notes',
                  hintText: isCall
                      ? 'What was discussed? Next step?'
                      : 'What happened on this lead?',
                ),
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
      ),
    );

    if (ok != true || !mounted) return;
    final note = noteController.text.trim();
    if (note.isEmpty) return;

    setState(() => _saving = true);
    try {
      if (isCall) {
        await SuperAdminDataService.updateMarketingLeadStatus(
          leadId: widget.lead.id,
          status: MarketingLeadStatus.contacted,
          markCalled: true,
          callOutcome: callOutcome,
          workedByName: selectedRep.name,
          workedByEmail: selectedRep.email,
          actorUid: _actorUid,
          actorEmail: _actorEmail,
          actorName: _actorName,
          summary: 'Call (${callOutcome.replaceAll('_', ' ')}) logged by '
              '${selectedRep.name}: $note',
        );
      }

      await SuperAdminDataService.addMarketingLeadActivity(
        leadId: widget.lead.id,
        type: isCall ? 'call_note' : 'note',
        summary: '${isCall ? 'Call' : 'Note'} by ${selectedRep.name}'
            '${isCall ? ' [${callOutcome.replaceAll('_', ' ')}]' : ''}: $note',
        actorUid: _actorUid,
        actorEmail: selectedRep.email,
        actorName: selectedRep.name,
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _assignLead() async {
    final reps = _repOptions();
    String selectedEmail = (widget.lead.assignedToEmail ?? '').trim();
    if (selectedEmail.isEmpty && reps.isNotEmpty) {
      selectedEmail = _selectedOrActorRep(reps).email;
    }
    bool clearAssignment = false;

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: const Text('Assign Lead'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              DropdownButtonFormField<String>(
                initialValue: selectedEmail.isEmpty ? null : selectedEmail,
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'Assign to rep'),
                items: reps
                    .map(
                      (rep) => DropdownMenuItem(
                        value: rep.email,
                        child: Text(rep.label),
                      ),
                    )
                    .toList(),
                onChanged: (value) {
                  setDialogState(() {
                    selectedEmail = value ?? '';
                    clearAssignment = false;
                  });
                },
              ),
              const SizedBox(height: 8),
              CheckboxListTile(
                value: clearAssignment,
                onChanged: (v) => setDialogState(() => clearAssignment = v == true),
                title: const Text('Unassign lead'),
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
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
              child: const Text('Assign'),
            ),
          ],
        ),
      ),
    );

    if (ok != true || !mounted) return;
    setState(() => _saving = true);
    try {
      final selectedRep = reps.where((r) => r.email == selectedEmail).toList();
      await SuperAdminDataService.assignMarketingLead(
        leadId: widget.lead.id,
        assignedToName:
            clearAssignment ? null : (selectedRep.isEmpty ? null : selectedRep.first.name),
        assignedToEmail:
            clearAssignment ? null : (selectedRep.isEmpty ? null : selectedRep.first.email),
        assignedToUid: null,
        actorUid: _actorUid,
        actorEmail: _actorEmail,
        actorName: _actorName,
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _deleteLead() async {
    final lead = widget.lead;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete lead?'),
        content: Text(
          'Permanently remove “${lead.name}” (${lead.email})? '
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
      await SuperAdminDataService.deleteMarketingLead(lead.id);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Lead deleted'),
            backgroundColor: AppTheme.success,
          ),
        );
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

  Future<void> _markOutcome({required bool won}) async {
    final amountController = TextEditingController();
    final noteController = TextEditingController();
    final reps = _repOptions();
    _RepOption selectedRep = _selectedOrActorRep(reps);

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: Text(won ? 'Mark Sale Won' : 'Mark Lead Lost'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              DropdownButtonFormField<String>(
                initialValue: selectedRep.email,
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'Worked by'),
                items: reps
                    .map(
                      (rep) => DropdownMenuItem(
                        value: rep.email,
                        child: Text(rep.label),
                      ),
                    )
                    .toList(),
                onChanged: (value) {
                  if (value == null) return;
                  setDialogState(() {
                    selectedRep =
                        reps.firstWhere((rep) => rep.email == value);
                  });
                },
              ),
              if (won) ...[
                const SizedBox(height: 8),
                TextField(
                  controller: amountController,
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                  decoration:
                      const InputDecoration(labelText: 'Sale amount (optional)'),
                ),
              ],
              const SizedBox(height: 8),
              TextField(
                controller: noteController,
                maxLines: 3,
                decoration: const InputDecoration(
                    labelText: 'Outcome notes',
                    hintText: 'What happened? What was sold/lost?'),
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
              child: Text(won ? 'Mark Won' : 'Mark Lost'),
            ),
          ],
        ),
      ),
    );

    if (ok != true || !mounted) return;
    final amount = num.tryParse(amountController.text.trim());
    final note = noteController.text.trim();
    if (won && (amount == null || amount <= 0)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Sale amount is required and must be greater than 0 for won leads.')),
      );
      return;
    }

    setState(() => _saving = true);
    try {
      await SuperAdminDataService.updateMarketingLeadStatus(
        leadId: widget.lead.id,
        status: won ? MarketingLeadStatus.won : MarketingLeadStatus.lost,
        saleStatus: won ? 'won' : 'lost',
        saleAmount: won ? amount : null,
        workedByName: selectedRep.name,
        workedByEmail: selectedRep.email,
        actorUid: _actorUid,
        actorEmail: _actorEmail,
        actorName: _actorName,
        summary: '${won ? 'Sale won' : 'Lead lost'} by ${selectedRep.name}'
            '${note.isEmpty ? '' : ': $note'}',
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final lead = widget.lead;
    final fmt = DateFormat('MMM d, yyyy h:mm a');
    final statusColor = _statusColor(lead.status);
    final createdAt = lead.createdAt != null ? fmt.format(lead.createdAt!) : '—';
    final shortLeadId = lead.id.length > 8 ? lead.id.substring(0, 8) : lead.id;
    final sourceDisplay = (lead.utmSource ?? '').trim().isNotEmpty
        ? (lead.utmSource ?? '').trim()
        : _sourceLabel(lead.source);
    final stale = _isStaleLead();

    return Container(
      decoration: BoxDecoration(
        color: Theme.of(context).cardColor,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppTheme.borderLight),
      ),
      child: ExpansionTile(
        tilePadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        title: Text(
          '${lead.name} • ${lead.facilityName}',
          style: Theme.of(context)
              .textTheme
              .titleSmall
              ?.copyWith(fontWeight: FontWeight.w600),
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${lead.email}${lead.phone == null || lead.phone!.isEmpty ? '' : ' • ${lead.phone}'}',
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: AppTheme.textSecondary),
            ),
            const SizedBox(height: 4),
            Wrap(
              spacing: 6,
              runSpacing: 4,
              children: [
                _metaPill(sourceDisplay),
                if ((lead.utmCampaign ?? '').trim().isNotEmpty)
                  _metaPill('Campaign: ${lead.utmCampaign}'),
                _metaPill('Lead #$shortLeadId'),
                if (stale) _metaPill('STALE ${widget.staleHours}h+', warning: true),
              ],
            ),
          ],
        ),
        trailing: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
          decoration: BoxDecoration(
            color: statusColor.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: statusColor.withValues(alpha: 0.3)),
          ),
          child: Text(
            lead.status.label,
            style: TextStyle(
                fontSize: 11, color: statusColor, fontWeight: FontWeight.w600),
          ),
        ),
        children: [
          const Divider(height: 1),
          const SizedBox(height: 12),
          Wrap(
            spacing: 24,
            runSpacing: 8,
            children: [
              _kv(context, 'Created', createdAt),
              _kv(context, 'Intent', lead.intent.toUpperCase()),
              _kv(context, 'Units', lead.unitCount?.isNotEmpty == true ? lead.unitCount! : '—'),
              _kv(context, 'Assigned', lead.assignedToName ?? lead.assignedToEmail ?? 'Unassigned'),
              _kv(context, 'Worked by', lead.workedByName ?? lead.workedByEmail ?? '—'),
              _kv(context, 'Call outcome', lead.lastCallOutcome?.replaceAll('_', ' ') ?? '—'),
              _kv(context, 'Source', sourceDisplay),
              _kv(context, 'Campaign', lead.utmCampaign ?? '—'),
              _kv(context, 'Sale status', lead.saleStatus),
              _kv(context, 'Sale amount', lead.saleAmount?.toString() ?? '—'),
              _kv(context, 'SMS consent', lead.smsConsent ? 'Yes' : 'No'),
            ],
          ),
          if (lead.message != null && lead.message!.trim().isNotEmpty) ...[
            const SizedBox(height: 10),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(8),
                color: AppTheme.backgroundLight,
                border: Border.all(color: AppTheme.borderLight),
              ),
              child: Text(
                lead.message!,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          ],
          const SizedBox(height: 8),
          if (_saving || _deleting)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 8),
              child: SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            )
          else
            Wrap(
              spacing: 6,
              runSpacing: 4,
              children: [
                TextButton.icon(
                  icon: const Icon(Icons.assignment_ind, size: 14),
                  label: const Text('Assign'),
                  onPressed: _assignLead,
                ),
                TextButton.icon(
                  icon: const Icon(Icons.call, size: 14),
                  label: const Text('Log Call'),
                  onPressed: () => _recordNote(isCall: true),
                ),
                TextButton.icon(
                  icon: const Icon(Icons.note_add, size: 14),
                  label: const Text('Add Note'),
                  onPressed: () => _recordNote(isCall: false),
                ),
                TextButton.icon(
                  icon: const Icon(Icons.check_circle, size: 14),
                  label: const Text('Mark Won'),
                  onPressed: () => _markOutcome(won: true),
                ),
                TextButton.icon(
                  icon: const Icon(Icons.cancel, size: 14),
                  label: const Text('Mark Lost'),
                  onPressed: () => _markOutcome(won: false),
                ),
                TextButton.icon(
                  icon: const Icon(Icons.delete_outline, size: 14),
                  label: const Text('Delete'),
                  style: TextButton.styleFrom(foregroundColor: AppTheme.error),
                  onPressed: _deleteLead,
                ),
              ],
            ),
          const SizedBox(height: 8),
          StreamBuilder<List<MarketingLeadActivity>>(
            stream: SuperAdminDataService.marketingLeadActivities(lead.id),
            builder: (context, snapshot) {
              final activities = snapshot.data ?? const <MarketingLeadActivity>[];
              if (activities.isEmpty) {
                return const SizedBox.shrink();
              }
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Activity',
                    style: Theme.of(context)
                        .textTheme
                        .labelLarge
                        ?.copyWith(fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 6),
                  ...activities.take(8).map((a) {
                    final when =
                        a.createdAt != null ? fmt.format(a.createdAt!) : '';
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 4),
                      child: Text(
                        '• $when — ${a.actorName}: ${a.summary}',
                        style: Theme.of(context)
                            .textTheme
                            .bodySmall
                            ?.copyWith(color: AppTheme.textSecondary),
                      ),
                    );
                  }),
                ],
              );
            },
          ),
        ],
      ),
    );
  }

  Widget _kv(BuildContext context, String label, String value) {
    return SizedBox(
      width: 210,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: Theme.of(context)
                .textTheme
                .bodySmall
                ?.copyWith(color: AppTheme.textTertiary),
          ),
          Text(value, style: Theme.of(context).textTheme.bodySmall),
        ],
      ),
    );
  }

  Widget _metaPill(String text, {bool warning = false}) {
    final bg = warning ? AppTheme.warning.withValues(alpha: 0.12) : AppTheme.backgroundLight;
    final border = warning ? AppTheme.warning.withValues(alpha: 0.35) : AppTheme.borderLight;
    final color = warning ? AppTheme.warning : AppTheme.textSecondary;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: border),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w600,
          color: color,
        ),
      ),
    );
  }
}

class _RepOption {
  final String name;
  final String email;

  const _RepOption({
    required this.name,
    required this.email,
  });

  String get label => '$name <$email>';
}
