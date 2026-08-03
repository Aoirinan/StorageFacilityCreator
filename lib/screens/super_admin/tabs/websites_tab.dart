import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:sfcapp/services/super_admin_data_service.dart';
import 'package:sfcapp/theme/app_theme.dart';

class WebsitesTab extends ConsumerStatefulWidget {
  const WebsitesTab({super.key});

  @override
  ConsumerState<WebsitesTab> createState() => _WebsitesTabState();
}

class _WebsitesTabState extends ConsumerState<WebsitesTab> {
  String _search = '';
  String _filter = 'all';

  void _refresh() {
    ref.invalidate(publicWebsiteAdminSettingsProvider);
    ref.invalidate(websiteAdminRowsProvider);
  }

  @override
  Widget build(BuildContext context) {
    final rowsAsync = ref.watch(websiteAdminRowsProvider);
    return rowsAsync.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (error, _) => Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('Could not load website subscriptions: $error'),
            const SizedBox(height: 12),
            FilledButton(
              onPressed: _refresh,
              child: const Text('Retry'),
            ),
          ],
        ),
      ),
      data: (rows) {
        final query = _search.trim().toLowerCase();
        final filtered = rows.where((row) {
          final facility = row.facility;
          final matchesSearch = query.isEmpty ||
              facility.name.toLowerCase().contains(query) ||
              facility.id.toLowerCase().contains(query) ||
              row.ownerEmail.toLowerCase().contains(query) ||
              (row.customDomain?.toLowerCase().contains(query) ?? false);
          final matchesFilter = switch (_filter) {
            'entitled' => facility.hasActiveWebsiteSubscription,
            'paid' => facility.hasActiveStripeWebsiteSubscription,
            'adminTrial' => facility.hasActiveWebsiteAdminTrial,
            'needsBase' => !row.hasActiveBaseSubscription,
            'inactive' => !facility.hasActiveWebsiteSubscription,
            _ => true,
          };
          return matchesSearch && matchesFilter;
        }).toList();

        return Column(
          children: [
            _toolbar(filtered.length, rows.length),
            Expanded(
              child: filtered.isEmpty
                  ? const Center(child: Text('No website subscriptions match.'))
                  : ListView.separated(
                      padding: const EdgeInsets.all(16),
                      itemCount: filtered.length,
                      separatorBuilder: (_, __) => const SizedBox(height: 8),
                      itemBuilder: (context, index) =>
                          _WebsiteRow(row: filtered[index]),
                    ),
            ),
          ],
        );
      },
    );
  }

  Widget _toolbar(int shown, int total) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      child: Wrap(
        spacing: 12,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          SizedBox(
            width: 420,
            child: TextField(
              decoration: InputDecoration(
                hintText: 'Search facility, owner, ID, or domain…',
                prefixIcon: const Icon(Icons.search, size: 18),
                isDense: true,
                border:
                    OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
              ),
              onChanged: (value) => setState(() => _search = value),
            ),
          ),
          DropdownButton<String>(
            value: _filter,
            items: const [
              DropdownMenuItem(value: 'all', child: Text('All')),
              DropdownMenuItem(value: 'entitled', child: Text('Has access')),
              DropdownMenuItem(value: 'paid', child: Text('Stripe paid')),
              DropdownMenuItem(value: 'adminTrial', child: Text('Admin trial')),
              DropdownMenuItem(
                  value: 'needsBase', child: Text('Missing \$75 base')),
              DropdownMenuItem(value: 'inactive', child: Text('No access')),
            ],
            onChanged: (value) => setState(() => _filter = value ?? 'all'),
          ),
          Text(
            '$shown / $total',
            style: Theme.of(context)
                .textTheme
                .bodySmall
                ?.copyWith(color: AppTheme.textSecondary),
          ),
          IconButton(
            tooltip: 'Refresh',
            onPressed: _refresh,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
    );
  }
}

class _WebsiteRow extends ConsumerStatefulWidget {
  const _WebsiteRow({required this.row});

  final WebsiteAdminRow row;

  @override
  ConsumerState<_WebsiteRow> createState() => _WebsiteRowState();
}

class _WebsiteRowState extends ConsumerState<_WebsiteRow> {
  bool _busy = false;

  String _date(DateTime? value) {
    if (value == null) return '—';
    return DateFormat('MMM d, yyyy h:mm a').format(value.toLocal());
  }

  Future<void> _manage({
    required String action,
    int? days,
    String? reason,
  }) async {
    setState(() => _busy = true);
    try {
      await SuperAdminDataService.manageWebsiteSubscription(
        facilityId: widget.row.facility.id,
        action: action,
        days: days,
        reason: reason,
      );
      ref.invalidate(publicWebsiteAdminSettingsProvider);
      ref.invalidate(websiteAdminRowsProvider);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(switch (action) {
              'grantTrial' => 'Website trial granted.',
              'extendTrial' => 'Website trial extended.',
              'revokeTrial' => 'Website trial revoked.',
              _ => 'Website subscription synchronized from Stripe.',
            }),
            backgroundColor: AppTheme.success,
          ),
        );
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Website action failed: $error'),
            backgroundColor: AppTheme.error,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _showTrialDialog({required bool extend}) async {
    var days = extend ? 14 : 30;
    final reasonController = TextEditingController();
    final result = await showDialog<({int days, String reason})>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text(extend ? 'Extend website trial' : 'Grant website trial'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'This grants website access without creating or changing a Stripe subscription.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 16),
              DropdownButtonFormField<int>(
                initialValue: days,
                decoration: const InputDecoration(
                  labelText: 'Duration',
                  border: OutlineInputBorder(),
                ),
                items: (extend ? const [7, 14, 30] : const [14, 30, 60])
                    .map((value) => DropdownMenuItem(
                          value: value,
                          child: Text('$value days'),
                        ))
                    .toList(),
                onChanged: (value) =>
                    setDialogState(() => days = value ?? days),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: reasonController,
                maxLength: 500,
                decoration: const InputDecoration(
                  labelText: 'Reason (optional)',
                  border: OutlineInputBorder(),
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(
                dialogContext,
                (days: days, reason: reasonController.text.trim()),
              ),
              child: Text(extend ? 'Extend' : 'Grant'),
            ),
          ],
        ),
      ),
    );
    reasonController.dispose();
    if (result == null || !mounted) return;
    await _manage(
      action: extend ? 'extendTrial' : 'grantTrial',
      days: result.days,
      reason: result.reason,
    );
  }

  Future<void> _confirmRevoke() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Revoke admin website trial?'),
        content: const Text(
          'This removes only the superadmin trial. It does not cancel or alter a paid Stripe subscription.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Revoke'),
          ),
        ],
      ),
    );
    if (confirmed == true && mounted) {
      await _manage(action: 'revokeTrial');
    }
  }

  Future<void> _confirmSync() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Repair from Stripe?'),
        content: const Text(
          'Stripe will be queried for this facility’s website subscription and its canonical status will replace the cached website billing fields.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Repair'),
          ),
        ],
      ),
    );
    if (confirmed == true && mounted) {
      await _manage(action: 'syncStripe');
    }
  }

  @override
  Widget build(BuildContext context) {
    final row = widget.row;
    final facility = row.facility;
    final stripeId = facility.stripeWebsiteSubscriptionId?.trim();
    final hasStripeId = stripeId != null && stripeId.isNotEmpty;

    return Card(
      child: ExpansionTile(
        leading: Icon(
          facility.hasActiveWebsiteSubscription
              ? Icons.language
              : Icons.language_outlined,
          color: facility.hasActiveWebsiteSubscription
              ? AppTheme.success
              : AppTheme.textSecondary,
        ),
        title: Text(
          facility.name.isEmpty ? facility.id : facility.name,
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
        subtitle: Text('${row.ownerEmail} • ${facility.id}'),
        trailing: Wrap(
          spacing: 6,
          children: [
            _StatusChip(
              label: row.hasActiveBaseSubscription
                  ? '\$75 base active'
                  : '\$75 base missing',
              color: row.hasActiveBaseSubscription
                  ? AppTheme.success
                  : AppTheme.error,
            ),
            _StatusChip(
              label: facility.hasActiveStripeWebsiteSubscription
                  ? '\$25 Stripe active'
                  : facility.hasActiveWebsiteAdminTrial
                      ? 'Admin trial'
                      : 'No website access',
              color: facility.hasActiveWebsiteSubscription
                  ? AppTheme.info
                  : AppTheme.textSecondary,
            ),
          ],
        ),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Divider(),
                Wrap(
                  spacing: 24,
                  runSpacing: 12,
                  children: [
                    _Detail(
                      label: 'Account base status',
                      value: row.accountSubscriptionStatus ?? 'Not linked',
                    ),
                    _Detail(
                      label: 'Facility base status',
                      value: facility.platformSubscriptionStatus ?? 'Not set',
                    ),
                    _Detail(
                      label: 'Website Stripe status',
                      value: facility.websiteSubscriptionStatus ?? 'Not set',
                    ),
                    _Detail(label: 'Website Stripe ID', value: stripeId ?? '—'),
                    _Detail(
                      label: 'Website period end',
                      value:
                          _date(facility.websiteSubscriptionCurrentPeriodEnd),
                    ),
                    _Detail(
                      label: 'Admin trial end',
                      value: _date(facility.websiteAdminTrialEndsAt),
                    ),
                    _Detail(
                      label: 'Granted by',
                      value: facility.websiteAdminTrialGrantedByEmail ?? '—',
                    ),
                    _Detail(
                      label: 'Grant reason',
                      value: facility.websiteAdminTrialReason ?? '—',
                    ),
                    _Detail(
                      label: 'Public site',
                      value: row.publicWebsiteConfigured
                          ? row.publicWebsiteEnabled
                              ? 'Configured and enabled'
                              : 'Configured but disabled'
                          : 'Not configured',
                    ),
                    _Detail(
                      label: 'Custom domain',
                      value: row.customDomain?.isNotEmpty == true
                          ? row.customDomain!
                          : '—',
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    FilledButton.tonalIcon(
                      onPressed:
                          _busy || facility.hasActiveStripeWebsiteSubscription
                              ? null
                              : () => _showTrialDialog(
                                  extend: facility.hasActiveWebsiteAdminTrial),
                      icon: const Icon(Icons.schedule),
                      label: Text(facility.hasActiveWebsiteAdminTrial
                          ? 'Extend trial'
                          : 'Grant trial'),
                    ),
                    OutlinedButton.icon(
                      onPressed: _busy || !facility.hasActiveWebsiteAdminTrial
                          ? null
                          : _confirmRevoke,
                      icon: const Icon(Icons.block),
                      label: const Text('Revoke trial'),
                    ),
                    OutlinedButton.icon(
                      onPressed: _busy || !hasStripeId ? null : _confirmSync,
                      icon: const Icon(Icons.sync),
                      label: const Text('Repair from Stripe'),
                    ),
                    if (_busy)
                      const Padding(
                        padding: EdgeInsets.all(8),
                        child: SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _StatusChip extends StatelessWidget {
  const _StatusChip({required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Chip(
      visualDensity: VisualDensity.compact,
      label: Text(label, style: const TextStyle(fontSize: 11)),
      side: BorderSide(color: color.withValues(alpha: 0.4)),
      backgroundColor: color.withValues(alpha: 0.1),
    );
  }
}

class _Detail extends StatelessWidget {
  const _Detail({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 240,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: Theme.of(context)
                .textTheme
                .labelSmall
                ?.copyWith(color: AppTheme.textSecondary),
          ),
          const SizedBox(height: 2),
          SelectableText(value),
        ],
      ),
    );
  }
}
