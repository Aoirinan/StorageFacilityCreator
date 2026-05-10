import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:sfcapp/models/facility_model.dart';
import 'package:sfcapp/services/facility_stats_service.dart';
import 'package:sfcapp/services/super_admin_data_service.dart';
import 'package:sfcapp/theme/app_theme.dart';

class MetricsTab extends ConsumerStatefulWidget {
  const MetricsTab({super.key});

  @override
  ConsumerState<MetricsTab> createState() => _MetricsTabState();
}

class _MetricsTabState extends ConsumerState<MetricsTab> {
  /// Facility ids we've already kicked off a stats refresh for this session,
  /// so we don't re-trigger writes on every widget rebuild.
  final Set<String> _backfilledFacilityIds = <String>{};

  /// One-shot per widget instance: extended backfill does async unit probes.
  bool _backfillScheduled = false;

  /// Mirror `unitDocCount` onto older facility docs. Uses a cheap heuristic first,
  /// then a `units` limit(1) probe when `unitDocCount` is still 0 so vacant-only
  /// sites (capacity unset, no occupancy) still get fixed.
  Future<void> _runUnitDocCountBackfill(List<FacilityModel> facilities) async {
    for (final f in facilities) {
      if (!mounted) return;
      if (_backfilledFacilityIds.contains(f.id)) continue;
      if (f.unitDocCount > 0) continue;

      final quickStale = f.totalUnits > 0 || f.occupiedUnits > 0;
      var needs = quickStale;
      if (!needs) {
        needs = await FacilityStatsService.facilityHasAnyUnitDoc(f.id);
      }
      if (!needs) continue;

      _backfilledFacilityIds.add(f.id);
      FacilityStatsService.updateFacilityStats(f.id);
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(allFacilitiesProvider).whenData((facilities) {
      if (_backfillScheduled) return;
      _backfillScheduled = true;
      unawaited(_runUnitDocCountBackfill(facilities));
    });

    final metricsAsync = ref.watch(platformMetricsProvider);
    final revenueAsync = ref.watch(platformTenantRevenueAggregateProvider);

    return metricsAsync.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(child: Text('Error loading metrics: $e')),
      data: (metrics) => SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Platform Overview',
                style: Theme.of(context)
                    .textTheme
                    .headlineSmall
                    ?.copyWith(fontWeight: FontWeight.bold)),
            const SizedBox(height: 20),
            _MetricGrid(metrics: metrics),
            const SizedBox(height: 20),
            _PlatformTenantRevenueCard(revenueAsync: revenueAsync),
            const SizedBox(height: 32),
            Text('Subscription Breakdown',
                style: Theme.of(context)
                    .textTheme
                    .titleMedium
                    ?.copyWith(fontWeight: FontWeight.bold)),
            const SizedBox(height: 16),
            _SubscriptionBreakdown(metrics: metrics),
          ],
        ),
      ),
    );
  }
}

class _PlatformTenantRevenueCard extends StatelessWidget {
  final AsyncValue<PlatformTenantRevenueSnapshot> revenueAsync;

  const _PlatformTenantRevenueCard({required this.revenueAsync});

  @override
  Widget build(BuildContext context) {
    return revenueAsync.when(
      loading: () => Container(
        width: double.infinity,
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: Theme.of(context).cardColor,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppTheme.borderLight),
        ),
        child: Row(
          children: [
            const SizedBox(
              width: 22,
              height: 22,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(width: 12),
            Text(
              'Loading tenant MRR from facility stats…',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
      error: (e, _) => Text(
        'Tenant revenue aggregate failed: $e',
        style: TextStyle(color: AppTheme.error, fontSize: 13),
      ),
      data: (rev) {
        if (rev.scheduledMonthlyRevenue <= 0 &&
            rev.autopayMonthlyRevenue <= 0) {
          return const SizedBox.shrink();
        }
        final fmt = NumberFormat.currency(symbol: r'$', decimalDigits: 0);
        final autopayPct = rev.scheduledMonthlyRevenue > 0
            ? (100 * rev.autopayMonthlyRevenue / rev.scheduledMonthlyRevenue)
                .clamp(0.0, 100.0)
            : 0.0;
        return Container(
          width: double.infinity,
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: Theme.of(context).cardColor,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: AppTheme.borderLight),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Tenant recurring revenue',
                style: Theme.of(context)
                    .textTheme
                    .titleSmall
                    ?.copyWith(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 4),
              Text(
                'Summed from each facility’s stats/current cache (active tenant rates).',
                style: Theme.of(context)
                    .textTheme
                    .bodySmall
                    ?.copyWith(color: AppTheme.textTertiary),
              ),
              const SizedBox(height: 12),
              Text(
                'Scheduled MRR: ${fmt.format(rev.scheduledMonthlyRevenue)}',
                style: Theme.of(context).textTheme.bodyLarge,
              ),
              const SizedBox(height: 4),
              Text(
                'On autopay: ${fmt.format(rev.autopayMonthlyRevenue)}'
                '${rev.scheduledMonthlyRevenue > 0 ? ' (${autopayPct.toStringAsFixed(0)}% of scheduled)' : ''}',
                style: Theme.of(context)
                    .textTheme
                    .bodyMedium
                    ?.copyWith(color: AppTheme.success),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _MetricGrid extends StatelessWidget {
  final PlatformMetrics metrics;
  const _MetricGrid({required this.metrics});

  @override
  Widget build(BuildContext context) {
    final cards = [
      _MetricCard(
        label: 'Total Facilities',
        value: '${metrics.totalFacilities}',
        sub: '${metrics.activeFacilities} active',
        icon: Icons.business,
        color: AppTheme.primaryBlue,
      ),
      _MetricCard(
        label: 'Total Units',
        value: '${metrics.totalUnits}',
        sub: '${metrics.occupiedUnits} occupied '
            '(${metrics.occupancyRate.toStringAsFixed(1)}%)',
        icon: Icons.door_front_door,
        color: AppTheme.success,
      ),
      _MetricCard(
        label: 'Accounts',
        value: '${metrics.totalAccounts}',
        sub: '${metrics.activeAccounts} paying',
        icon: Icons.account_circle,
        color: AppTheme.accentOrange,
      ),
      _MetricCard(
        label: 'Platform Users',
        value: '${metrics.totalUsers}',
        sub: 'across all facilities',
        icon: Icons.people,
        color: AppTheme.primaryBlueLight,
      ),
    ];

    return LayoutBuilder(builder: (context, constraints) {
      final crossCount = constraints.maxWidth > 800 ? 4 : 2;
      return GridView.count(
        crossAxisCount: crossCount,
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        crossAxisSpacing: 16,
        mainAxisSpacing: 16,
        childAspectRatio: 1.6,
        children: cards,
      );
    });
  }
}

class _MetricCard extends StatelessWidget {
  final String label;
  final String value;
  final String sub;
  final IconData icon;
  final Color color;

  const _MetricCard({
    required this.label,
    required this.value,
    required this.sub,
    required this.icon,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Theme.of(context).cardColor,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.borderLight),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.04),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Row(
            children: [
              Icon(icon, color: color, size: 20),
              const SizedBox(width: 8),
              Expanded(
                child: Text(label,
                    style: Theme.of(context)
                        .textTheme
                        .bodySmall
                        ?.copyWith(color: AppTheme.textSecondary)),
              ),
            ],
          ),
          Text(value,
              style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                    color: color,
                  )),
          Text(sub,
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: AppTheme.textTertiary)),
        ],
      ),
    );
  }
}

class _SubscriptionBreakdown extends StatelessWidget {
  final PlatformMetrics metrics;
  const _SubscriptionBreakdown({required this.metrics});

  @override
  Widget build(BuildContext context) {
    final rows = [
      ('Active', metrics.activeAccounts, AppTheme.success),
      ('Trialing', metrics.trialingAccounts, AppTheme.info),
      ('Past Due', metrics.pastDueAccounts, AppTheme.warning),
      ('Cancelled', metrics.cancelledAccounts, AppTheme.error),
    ];

    return Container(
      decoration: BoxDecoration(
        color: Theme.of(context).cardColor,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.borderLight),
      ),
      child: Column(
        children: rows.map((r) {
          final (label, count, color) = r;
          final pct = metrics.totalAccounts == 0
              ? 0.0
              : count / metrics.totalAccounts;
          return Padding(
            padding:
                const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
            child: Row(
              children: [
                Container(
                  width: 10,
                  height: 10,
                  decoration: BoxDecoration(
                    color: color,
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 12),
                SizedBox(
                  width: 90,
                  child: Text(label,
                      style: Theme.of(context).textTheme.bodyMedium),
                ),
                Expanded(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: LinearProgressIndicator(
                      value: pct,
                      backgroundColor: AppTheme.borderLight,
                      valueColor: AlwaysStoppedAnimation<Color>(color),
                      minHeight: 8,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                SizedBox(
                  width: 40,
                  child: Text('$count',
                      textAlign: TextAlign.right,
                      style: Theme.of(context)
                          .textTheme
                          .bodyMedium
                          ?.copyWith(fontWeight: FontWeight.bold)),
                ),
              ],
            ),
          );
        }).toList(),
      ),
    );
  }
}
