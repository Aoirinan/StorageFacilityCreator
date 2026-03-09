import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sfcapp/services/super_admin_data_service.dart';
import 'package:sfcapp/theme/app_theme.dart';

class MetricsTab extends ConsumerWidget {
  const MetricsTab({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final metricsAsync = ref.watch(platformMetricsProvider);

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
