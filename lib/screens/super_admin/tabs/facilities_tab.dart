import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:sfcapp/services/super_admin_data_service.dart';
import 'package:sfcapp/theme/app_theme.dart';

class FacilitiesTab extends ConsumerStatefulWidget {
  const FacilitiesTab({super.key});

  @override
  ConsumerState<FacilitiesTab> createState() => _FacilitiesTabState();
}

class _FacilitiesTabState extends ConsumerState<FacilitiesTab> {
  String _search = '';
  String _statusFilter = 'all'; // all | active | archived

  @override
  Widget build(BuildContext context) {
    final rowsAsync = ref.watch(superAdminFacilityRowsProvider);

    return rowsAsync.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(child: Text('Error: $e')),
      data: (rows) {
        var filtered = rows.where((r) {
          final q = _search.toLowerCase();
          final matchSearch = q.isEmpty ||
              r.facility.name.toLowerCase().contains(q) ||
              r.ownerEmail.toLowerCase().contains(q) ||
              r.facility.id.toLowerCase().contains(q) ||
              r.facility.ownerUid.toLowerCase().contains(q) ||
              (r.facility.address?.toLowerCase().contains(q) ?? false);
          final matchStatus = _statusFilter == 'all' ||
              (_statusFilter == 'active' && r.facility.active) ||
              (_statusFilter == 'archived' && !r.facility.active);
          return matchSearch && matchStatus;
        }).toList();

        return Column(
          children: [
            _buildToolbar(filtered.length, rows.length),
            Expanded(
              child: filtered.isEmpty
                  ? const Center(child: Text('No facilities match your filter.'))
                  : ListView.separated(
                      padding: const EdgeInsets.all(16),
                      itemCount: filtered.length,
                      separatorBuilder: (_, __) => const SizedBox(height: 8),
                      itemBuilder: (context, i) =>
                          _FacilityRow(row: filtered[i]),
                    ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildToolbar(int shown, int total) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              decoration: InputDecoration(
                hintText: 'Search by name, email, address, facility ID…',
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
          DropdownButton<String>(
            value: _statusFilter,
            items: const [
              DropdownMenuItem(value: 'all', child: Text('All')),
              DropdownMenuItem(value: 'active', child: Text('Active')),
              DropdownMenuItem(value: 'archived', child: Text('Archived')),
            ],
            onChanged: (v) => setState(() => _statusFilter = v!),
          ),
          const SizedBox(width: 12),
          Text('$shown / $total',
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: AppTheme.textSecondary)),
        ],
      ),
    );
  }
}

class _FacilityRow extends ConsumerWidget {
  final SuperAdminFacilityRow row;
  const _FacilityRow({required this.row});

  Future<void> _onDeletePressed(BuildContext context, WidgetRef ref) async {
    final f = row.facility;
    final expected = f.name.trim().isEmpty ? f.id : f.name.trim();
    final hint = f.name.trim().isEmpty
        ? 'This facility has no name. Type its Facility ID to confirm.'
        : 'Type the facility name exactly (including spaces and capitalization) to confirm.';
    final controller = TextEditingController();

    final proceed = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete facility permanently?'),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'This removes all Firestore data for this facility, deletes files in '
                'Firebase Storage under this facility (contracts, uploads, branding, etc.), '
                'unlinks it from the creator account, removes the public map entry if present, '
                'and updates Stripe subscription quantity. This cannot be undone.',
                style: Theme.of(ctx).textTheme.bodySmall,
              ),
              const SizedBox(height: 12),
              Text(hint, style: Theme.of(ctx).textTheme.bodySmall),
              const SizedBox(height: 8),
              TextField(
                controller: controller,
                decoration: const InputDecoration(
                  labelText: 'Confirmation',
                  border: OutlineInputBorder(),
                ),
                autofocus: true,
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppTheme.error),
            onPressed: () {
              if (controller.text.trim() != expected) {
                ScaffoldMessenger.of(ctx).showSnackBar(
                  const SnackBar(
                    content: Text('Confirmation does not match.'),
                    backgroundColor: AppTheme.error,
                  ),
                );
                return;
              }
              Navigator.pop(ctx, true);
            },
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (proceed != true || !context.mounted) return;

    final messenger = ScaffoldMessenger.of(context);
    messenger.showSnackBar(
      const SnackBar(content: Text('Deleting facility…')),
    );
    try {
      await SuperAdminDataService.deleteFacility(
        facilityId: f.id,
        facilityNameConfirmation: expected,
      );
      messenger.hideCurrentSnackBar();
      messenger.showSnackBar(
        const SnackBar(
          content: Text('Facility deleted.'),
          backgroundColor: AppTheme.success,
        ),
      );
      ref.invalidate(superAdminFacilityRowsProvider);
    } catch (e) {
      messenger.hideCurrentSnackBar();
      messenger.showSnackBar(
        SnackBar(
          content: Text('Delete failed: $e'),
          backgroundColor: AppTheme.error,
        ),
      );
    }
  }

  Future<void> _onRepairPermissionOrphans(BuildContext context) async {
    final f = row.facility;
    final proceed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Repair permission orphans?'),
        content: Text(
          'This deactivates active staff role rows for this facility when the '
          'Firestore user profile no longer exists (for example after deleting '
          'the user from super admin). It also removes their entry from the '
          'facility roles map.',
          style: Theme.of(ctx).textTheme.bodySmall,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Repair'),
          ),
        ],
      ),
    );

    if (proceed != true || !context.mounted) return;

    final messenger = ScaffoldMessenger.of(context);
    messenger.showSnackBar(
      const SnackBar(content: Text('Repairing permissions…')),
    );
    try {
      final n =
          await SuperAdminDataService.repairFacilityPermissionOrphans(f.id);
      messenger.hideCurrentSnackBar();
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            n == 0
                ? 'No orphan role assignments found.'
                : 'Deactivated $n orphan role assignment(s).',
          ),
          backgroundColor: n == 0 ? null : AppTheme.success,
        ),
      );
    } catch (e) {
      messenger.hideCurrentSnackBar();
      messenger.showSnackBar(
        SnackBar(
          content: Text('Repair failed: $e'),
          backgroundColor: AppTheme.error,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final f = row.facility;
    final dateStr = DateFormat('MMM d, yyyy').format(f.createdAt);
    // Show actual unit-document count, not the editable capacity max.
    final totalUnitsActual = f.unitDocCount;
    final occupancy = totalUnitsActual == 0
        ? 0.0
        : f.occupiedUnits / totalUnitsActual;

    return Container(
      decoration: BoxDecoration(
        color: Theme.of(context).cardColor,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
            color: f.active ? AppTheme.borderLight : AppTheme.borderMedium),
      ),
      child: ExpansionTile(
        tilePadding:
            const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        childrenPadding:
            const EdgeInsets.fromLTRB(16, 0, 16, 16),
        leading: CircleAvatar(
          backgroundColor:
              f.active ? AppTheme.primaryBlue.withValues(alpha: 0.1) : Colors.grey.withValues(alpha: 0.1),
          child: Icon(Icons.business,
              color: f.active ? AppTheme.primaryBlue : Colors.grey,
              size: 18),
        ),
        title: Row(
          children: [
            Expanded(
              child: Text(f.name,
                  style: Theme.of(context)
                      .textTheme
                      .titleSmall
                      ?.copyWith(fontWeight: FontWeight.w600)),
            ),
            if (!f.active)
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: Colors.grey.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Text('Archived',
                    style: TextStyle(fontSize: 11, color: Colors.grey)),
              ),
          ],
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(row.ownerEmail,
                style: Theme.of(context)
                    .textTheme
                    .bodySmall
                    ?.copyWith(color: AppTheme.textSecondary)),
            const SizedBox(height: 3),
            _FacilityUsageInline(facilityId: f.id),
          ],
        ),
        trailing: _SubscriptionChip(status: row.subscriptionStatus),
        children: [
          const Divider(height: 1),
          const SizedBox(height: 12),
          _DetailGrid(children: [
            _Detail('Signed Up', dateStr),
            _Detail('Facility ID', f.id, selectable: true),
            _Detail('Address', f.address ?? '—'),
            _Detail('Phone', f.phone ?? '—'),
            _Detail('Email', f.email ?? '—'),
            _Detail('Units',
                '${f.occupiedUnits} / $totalUnitsActual (${(occupancy * 100).toStringAsFixed(0)}%)'),
            _Detail('Stripe Connect',
                f.stripeConnectOnboardingComplete ? 'Connected' : 'Not connected'),
            if (row.subscriptionPeriodEnd != null)
              _Detail('Period End',
                  DateFormat('MMM d, yyyy').format(row.subscriptionPeriodEnd!)),
          ]),
          const SizedBox(height: 10),
          _FacilityCommunicationUsageCard(facilityId: f.id),
          const SizedBox(height: 8),
          Wrap(
            spacing: 4,
            runSpacing: 4,
            children: [
              TextButton.icon(
                icon: const Icon(Icons.copy, size: 14),
                label: const Text('Copy ID'),
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: f.id));
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                        content: Text('Facility ID copied'),
                        duration: Duration(seconds: 1)),
                  );
                },
              ),
              TextButton.icon(
                icon: const Icon(Icons.copy, size: 14),
                label: const Text('Copy Owner UID'),
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: f.ownerUid));
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                        content: Text('Owner UID copied'),
                        duration: Duration(seconds: 1)),
                  );
                },
              ),
              TextButton.icon(
                icon: const Icon(Icons.badge_outlined, size: 16),
                label: const Text('Repair permission orphans'),
                onPressed: () => _onRepairPermissionOrphans(context),
              ),
              TextButton.icon(
                icon: const Icon(Icons.delete_outline, size: 16),
                label: const Text('Delete facility'),
                style: TextButton.styleFrom(foregroundColor: AppTheme.error),
                onPressed: () => _onDeletePressed(context, ref),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _SubscriptionChip extends StatelessWidget {
  final String? status;
  const _SubscriptionChip({this.status});

  @override
  Widget build(BuildContext context) {
    if (status == null) return const SizedBox.shrink();
    Color color;
    switch (status!.toLowerCase()) {
      case 'active':
        color = AppTheme.success;
        break;
      case 'trial':
        color = AppTheme.info;
        break;
      case 'past due':
        color = AppTheme.warning;
        break;
      case 'cancelled':
      case 'unpaid':
        color = AppTheme.error;
        break;
      default:
        color = AppTheme.textTertiary;
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Text(status!,
          style: TextStyle(
              fontSize: 11, color: color, fontWeight: FontWeight.w600)),
    );
  }
}

class _DetailGrid extends StatelessWidget {
  final List<_Detail> children;
  const _DetailGrid({required this.children});

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 24,
      runSpacing: 8,
      children: children
          .map((d) => SizedBox(
                width: 200,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(d.label,
                        style: Theme.of(context)
                            .textTheme
                            .bodySmall
                            ?.copyWith(color: AppTheme.textTertiary)),
                    d.selectable
                        ? SelectableText(
                            d.value,
                            style: Theme.of(context).textTheme.bodySmall,
                          )
                        : Text(d.value,
                            style: Theme.of(context).textTheme.bodySmall),
                  ],
                ),
              ))
          .toList(),
    );
  }
}

class _Detail {
  final String label;
  final String value;
  final bool selectable;
  const _Detail(this.label, this.value, {this.selectable = false});
}

class _FacilityCommunicationUsageCard extends StatelessWidget {
  const _FacilityCommunicationUsageCard({required this.facilityId});

  final String facilityId;

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<FacilityCommunicationUsage>(
      future: SuperAdminDataService.getFacilityCommunicationUsage(facilityId),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const SizedBox(
            height: 40,
            child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
          );
        }
        final usage = snapshot.data;
        if (usage == null) {
          return const SizedBox.shrink();
        }
        final emailPct = usage.emailUsage.percentage;
        final smsPct = usage.smsUsage.percentage;
        return Container(
          width: double.infinity,
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: AppTheme.backgroundLight,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: AppTheme.borderLight),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Messaging usage (this month)',
                style: Theme.of(context)
                    .textTheme
                    .labelLarge
                    ?.copyWith(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 6),
              Text(
                'Emails: ${usage.emailUsage.currentCount}/${usage.emailUsage.monthlyLimit} (${emailPct.toStringAsFixed(1)}%)',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              Text(
                'Texts: ${usage.smsUsage.currentCount}/${usage.smsUsage.monthlyLimit} (${smsPct.toStringAsFixed(1)}%)',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
        );
      },
    );
  }
}

class _FacilityUsageInline extends StatelessWidget {
  const _FacilityUsageInline({required this.facilityId});

  final String facilityId;

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<FacilityCommunicationUsage>(
      future: SuperAdminDataService.getFacilityCommunicationUsage(facilityId),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return Text(
            'Usage: loading...',
            style: Theme.of(context)
                .textTheme
                .bodySmall
                ?.copyWith(color: AppTheme.textTertiary),
          );
        }
        if (snapshot.hasError || snapshot.data == null) {
          return Text(
            'Usage unavailable',
            style: Theme.of(context)
                .textTheme
                .bodySmall
                ?.copyWith(color: AppTheme.warning),
          );
        }
        final usage = snapshot.data!;
        return Text(
          'Emails ${usage.emailUsage.currentCount}/${usage.emailUsage.monthlyLimit} • '
          'Texts ${usage.smsUsage.currentCount}/${usage.smsUsage.monthlyLimit}',
          style: Theme.of(context)
              .textTheme
              .bodySmall
              ?.copyWith(color: AppTheme.textTertiary),
        );
      },
    );
  }
}
