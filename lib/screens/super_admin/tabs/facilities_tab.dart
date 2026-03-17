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
                hintText: 'Search by name, email, address…',
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

class _FacilityRow extends StatelessWidget {
  final SuperAdminFacilityRow row;
  const _FacilityRow({required this.row});

  @override
  Widget build(BuildContext context) {
    final f = row.facility;
    final dateStr = DateFormat('MMM d, yyyy').format(f.createdAt);
    final occupancy = f.totalUnits == 0
        ? 0.0
        : f.occupiedUnits / f.totalUnits;

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
        subtitle: Text(row.ownerEmail,
            style: Theme.of(context)
                .textTheme
                .bodySmall
                ?.copyWith(color: AppTheme.textSecondary)),
        trailing: _SubscriptionChip(status: row.subscriptionStatus),
        children: [
          const Divider(height: 1),
          const SizedBox(height: 12),
          _DetailGrid(children: [
            _Detail('Signed Up', dateStr),
            _Detail('Address', f.address ?? '—'),
            _Detail('Phone', f.phone ?? '—'),
            _Detail('Email', f.email ?? '—'),
            _Detail('Units',
                '${f.occupiedUnits} / ${f.totalUnits} (${(occupancy * 100).toStringAsFixed(0)}%)'),
            _Detail('Stripe Connect',
                f.stripeConnectOnboardingComplete ? 'Connected' : 'Not connected'),
            if (row.subscriptionPeriodEnd != null)
              _Detail('Period End',
                  DateFormat('MMM d, yyyy').format(row.subscriptionPeriodEnd!)),
          ]),
          const SizedBox(height: 10),
          _FacilityCommunicationUsageCard(facilityId: f.id),
          const SizedBox(height: 8),
          Row(
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
                    Text(d.value,
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
  const _Detail(this.label, this.value);
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
