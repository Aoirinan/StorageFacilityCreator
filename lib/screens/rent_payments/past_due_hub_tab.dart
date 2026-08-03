import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../providers/active_facility_provider.dart';
import '../../providers/auth_provider.dart';
import '../../providers/facility_provider.dart';
import '../../providers/late_logic_provider.dart';
import '../../models/facility_model.dart';
import '../../models/payment_model.dart';
import '../../router/app_route.dart';
import '../../services/facility_creator_account_service.dart';
import '../../services/late_logic_service.dart';
import '../../services/tenant_service.dart';
import '../../theme/app_theme.dart';
import '../../widgets/badge_widget.dart';
/// Past due hub tab: late stats + overdue payments/tenants (Delinquency Overview + Past Due merged).
class PastDueHubTab extends ConsumerStatefulWidget {
  const PastDueHubTab({super.key});

  @override
  ConsumerState<PastDueHubTab> createState() => _PastDueHubTabState();
}

class _PastDueHubTabState extends ConsumerState<PastDueHubTab> {
  String? _selectedFacilityId;

  @override
  void initState() {
    super.initState();
    _loadUserFacilities();
  }

  Future<void> _loadUserFacilities() async {
    final authState = ref.read(authStateProvider);
    if (authState.hasValue && authState.value != null) {
      try {
        await FacilityCreatorAccountService.getOrCreateAccountForCurrentUser();
        ref.invalidate(userFacilitiesProvider(authState.value!.uid));
        final facilitiesAsync =
            await ref.read(userFacilitiesProvider(authState.value!.uid).future);
        final facilities =
            facilitiesAsync as List<FacilityModel>? ?? <FacilityModel>[];
        if (facilities.isNotEmpty && mounted) {
          final activeId =
              ref.read(activeFacilityIdProvider).whenOrNull(data: (d) => d);
          final id = activeId != null && facilities.any((f) => f.id == activeId)
              ? activeId
              : facilities.first.id;
          setState(() => _selectedFacilityId = id);
        }
      } catch (_) {}
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(activeFacilityIdProvider, (prev, next) {
      final nextId = next.whenOrNull(data: (d) => d);
      if (nextId != null && _selectedFacilityId != nextId && mounted) {
        setState(() => _selectedFacilityId = nextId);
      }
    });

    final auth = ref.watch(authStateProvider);
    final activeId =
        ref.watch(activeFacilityIdProvider).whenOrNull(data: (d) => d);
    final facilities = auth.whenOrNull(data: (d) => d) != null
        ? ref
            .watch(userFacilitiesProvider(auth.whenOrNull(data: (d) => d)!.uid))
            .whenOrNull(data: (d) => d)
        : null;

    String? effectiveId = _selectedFacilityId;
    if (effectiveId == null && facilities != null && facilities.isNotEmpty) {
      effectiveId = (activeId != null && facilities.any((f) => f.id == activeId))
          ? activeId
          : facilities.first.id;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _selectedFacilityId != effectiveId) {
          setState(() => _selectedFacilityId = effectiveId);
        }
      });
    }

    if (effectiveId == null) {
      return _buildNoFacilitiesMessage(context);
    }

    final facilityId = effectiveId;
    final facilityAsync = ref.watch(facilityProvider(facilityId));

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildHowLateWorks(
            context,
            facilityAsync.whenOrNull(data: (d) => d),
          ),
          const SizedBox(height: 16),
          _buildStatistics(context, ref, facilityId),
          const SizedBox(height: 24),
          _buildOverduePayments(context, ref, facilityId),
          const SizedBox(height: 24),
          _buildTenantsWithOverdue(context, ref, facilityId),
          const SizedBox(height: 24),
          Center(
            child: OutlinedButton.icon(
              onPressed: () => context.push(AppRoute.dnr),
              icon: const Icon(Icons.block),
              label: const Text('Manage Do Not Rent list'),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildNoFacilitiesMessage(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.business, size: 64, color: colorScheme.onSurfaceVariant),
          const SizedBox(height: 16),
          Text(
            'No Facilities Found',
            style: Theme.of(context).textTheme.headlineSmall,
          ),
          const SizedBox(height: 8),
          Text(
            'Create a facility to track past-due tenants.',
            style: Theme.of(context).textTheme.bodyMedium,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 24),
          ElevatedButton(
            onPressed: () => context.go(AppRoute.facilityNew),
            child: const Text('Create Facility'),
          ),
        ],
      ),
    );
  }

  Widget _buildHowLateWorks(BuildContext context, FacilityModel? facility) {
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest.withOpacity(0.5),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: colorScheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.info_outline, size: 20, color: colorScheme.primary),
              const SizedBox(width: 8),
              Text(
                'How we determine who\'s late',
                style: Theme.of(context).textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w600,
                      color: colorScheme.onSurface,
                    ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            'A tenant is marked late when their paid-through date is before the start of the current month minus your grace period. Set grace period and late fees in Facility → Billing settings.',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                ),
          ),
          if (facility != null) ...[
            const SizedBox(height: 10),
            TextButton.icon(
              onPressed: () {
                context.push(
                  '${AppRoute.facilityEdit}?facilityId=${facility.id}',
                  extra: facility,
                );
              },
              icon: const Icon(Icons.settings, size: 18),
              label: const Text('Edit grace period & late fees'),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildStatistics(
    BuildContext context,
    WidgetRef ref,
    String facilityId,
  ) {
    return ref.watch(lateStatisticsProvider(facilityId)).when(
          data: (stats) => Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Late Payment Statistics',
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                  ),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      Expanded(
                        child: _statCard(
                          'Current',
                          '${stats['current'] ?? 0}',
                          AppTheme.success,
                          Icons.check_circle,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: _statCard(
                          'Late',
                          '${stats['late'] ?? 0}',
                          AppTheme.warning,
                          Icons.warning,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: _statCard(
                          'Overdue',
                          '${stats['overdue'] ?? 0}',
                          AppTheme.error,
                          Icons.error,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: _statCard(
                          'Severely Overdue',
                          '${stats['severelyOverdue'] ?? 0}',
                          AppTheme.error,
                          Icons.dangerous,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      Expanded(
                        child: _statCard(
                          'Total Tenants with Overdue',
                          '${stats['totalTenantsWithOverdue'] ?? 0}',
                          AppTheme.primaryBlue,
                          Icons.people,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (error, _) => Center(
            child: Column(
              children: [
                Icon(Icons.error, color: AppTheme.error, size: 64),
                const SizedBox(height: 16),
                Text('Error loading statistics: $error'),
                const SizedBox(height: 16),
                ElevatedButton(
                  onPressed: () =>
                      ref.invalidate(lateStatisticsProvider(facilityId)),
                  child: const Text('Retry'),
                ),
              ],
            ),
          ),
        );
  }

  Widget _statCard(String title, String value, Color color, IconData icon) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          children: [
            Icon(icon, color: color, size: 32),
            const SizedBox(height: 8),
            Text(
              value,
              style: TextStyle(
                fontSize: 24,
                fontWeight: FontWeight.bold,
                color: color,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              title,
              style: const TextStyle(fontSize: 12),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildOverduePayments(
    BuildContext context,
    WidgetRef ref,
    String facilityId,
  ) {
    final paymentsAsync = ref.watch(overduePaymentsProvider(facilityId));
    final tenantsAsync = ref.watch(tenantsWithOverdueProvider(facilityId));
    return paymentsAsync.when(
      data: (payments) {
        return tenantsAsync.when(
          data: (tenantsWithOverdue) {
            final hasOverdueByTenants = tenantsWithOverdue.isNotEmpty;
            final hasOverdueByPayments = payments.isNotEmpty;
            final countLabel = hasOverdueByPayments
                ? '${payments.length} payments'
                : hasOverdueByTenants
                    ? '${tenantsWithOverdue.length} tenant(s) with overdue balance'
                    : '0 payments';
            return Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          'Overdue Payments',
                          style:
                              Theme.of(context).textTheme.titleLarge?.copyWith(
                                    fontWeight: FontWeight.bold,
                                  ),
                        ),
                        Text(
                          countLabel,
                          style:
                              Theme.of(context).textTheme.bodyMedium?.copyWith(
                                    color: hasOverdueByPayments ||
                                            hasOverdueByTenants
                                        ? AppTheme.error
                                        : AppTheme.textSecondary,
                                  ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    if (payments.isNotEmpty)
                      ListView.builder(
                        shrinkWrap: true,
                        physics: const NeverScrollableScrollPhysics(),
                        itemCount: payments.length,
                        itemBuilder: (context, index) {
                          return _paymentCard(
                            context,
                            ref,
                            payments[index],
                            facilityId,
                          );
                        },
                      )
                    else if (tenantsWithOverdue.isNotEmpty)
                      Center(
                        child: Column(
                          children: [
                            Icon(Icons.warning_amber_rounded,
                                color: AppTheme.warning, size: 64),
                            const SizedBox(height: 16),
                            Text(
                              '${tenantsWithOverdue.length} tenant(s) with overdue balance',
                              style: Theme.of(context).textTheme.titleMedium,
                              textAlign: TextAlign.center,
                            ),
                          ],
                        ),
                      )
                    else
                      Center(
                        child: Column(
                          children: [
                            Icon(Icons.check_circle,
                                color: AppTheme.success, size: 64),
                            const SizedBox(height: 16),
                            Text(
                              'No overdue payments',
                              style: Theme.of(context).textTheme.titleMedium,
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
            );
          },
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (error, _) => Center(child: Text('Error loading tenants: $error')),
        );
      },
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (error, _) =>
          Center(child: Text('Error loading overdue payments: $error')),
    );
  }

  Widget _buildTenantsWithOverdue(
    BuildContext context,
    WidgetRef ref,
    String facilityId,
  ) {
    return ref.watch(tenantsWithOverdueProvider(facilityId)).when(
          data: (tenants) => Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        'Tenants with Overdue Payments',
                        style: Theme.of(context).textTheme.titleLarge?.copyWith(
                              fontWeight: FontWeight.bold,
                            ),
                      ),
                      Text(
                        '${tenants.length} tenants',
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                              color: AppTheme.textSecondary,
                            ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  if (tenants.isEmpty)
                    Center(
                      child: Column(
                        children: [
                          Icon(Icons.check_circle,
                              color: AppTheme.success, size: 64),
                          const SizedBox(height: 16),
                          Text(
                            'No tenants with overdue payments',
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                        ],
                      ),
                    )
                  else
                    ListView.builder(
                      shrinkWrap: true,
                      physics: const NeverScrollableScrollPhysics(),
                      itemCount: tenants.length,
                      itemBuilder: (context, index) {
                        return _tenantCard(
                          context,
                          ref,
                          tenants[index],
                          facilityId,
                        );
                      },
                    ),
                ],
              ),
            ),
          ),
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (error, _) => Center(child: Text('Error loading tenants: $error')),
        );
  }

  Widget _paymentCard(
    BuildContext context,
    WidgetRef ref,
    PaymentModel payment,
    String facilityId,
  ) {
    final badgeInfo = ref.read(paymentBadgeProvider(payment));
    final lateFee = LateLogicService.calculateLateFee(payment);

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: _colorFromString(badgeInfo.color),
          child: Icon(_iconFromString(badgeInfo.icon), color: AppTheme.textOnDark),
        ),
        title: Text(
          '\$${payment.amount.toStringAsFixed(2)}',
          style: const TextStyle(fontWeight: FontWeight.bold),
        ),
        subtitle: FutureBuilder<String?>(
          future: _tenantUnitNumber(payment.tenantId, facilityId),
          builder: (context, snapshot) {
            final unitNumber = snapshot.data;
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (unitNumber != null && unitNumber.isNotEmpty)
                  Text(
                    'Unit: $unitNumber',
                    style: const TextStyle(
                      fontWeight: FontWeight.w600,
                      color: AppTheme.primaryBlue,
                    ),
                  ),
                Text('Due: ${_formatDate(payment.dueDate)}'),
                Text('Days overdue: ${payment.daysOverdue}'),
                if (lateFee > 0)
                  Text(
                    'Late fee: \$${lateFee.toStringAsFixed(2)}',
                    style: TextStyle(color: AppTheme.error),
                  ),
              ],
            );
          },
        ),
        trailing: BadgeWidget(badgeInfo: badgeInfo),
        onTap: () => context.push(AppRoute.paymentDetail, extra: payment),
      ),
    );
  }

  Widget _tenantCard(
    BuildContext context,
    WidgetRef ref,
    TenantOverdueInfo tenantInfo,
    String facilityId,
  ) {
    final badgeInfo = LateLogicService.getTenantBadge(tenantInfo.status);

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: _colorFromString(badgeInfo.color),
          child: Icon(_iconFromString(badgeInfo.icon), color: Colors.white),
        ),
        title: Text(tenantInfo.tenant.name),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              tenantInfo.tenant.email?.isNotEmpty == true
                  ? tenantInfo.tenant.email!
                  : 'No email on file',
            ),
            if (tenantInfo.tenant.unitNumber.isNotEmpty)
              Text(
                'Unit: ${tenantInfo.tenant.unitNumber}',
                style: const TextStyle(
                  fontWeight: FontWeight.w600,
                  color: AppTheme.primaryBlue,
                ),
              ),
            Text(
              'Balance: \$${tenantInfo.totalBalance.toStringAsFixed(2)}',
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            if (tenantInfo.maxDaysOverdue > 0)
              Text(LateLogicService.formatDaysOverdue(tenantInfo.maxDaysOverdue)),
          ],
        ),
        trailing: BadgeWidget(badgeInfo: badgeInfo),
        onTap: () => context.push(AppRoute.tenantDetail, extra: tenantInfo.tenant),
      ),
    );
  }

  Future<String?> _tenantUnitNumber(String tenantId, String facilityId) async {
    try {
      final tenant = await TenantService.getTenantById(facilityId, tenantId);
      return tenant?.unitNumber;
    } catch (_) {
      return null;
    }
  }

  String _formatDate(DateTime date) =>
      '${date.month}/${date.day}/${date.year}';

  Color _colorFromString(String colorString) {
    switch (colorString.toLowerCase()) {
      case 'green':
        return AppTheme.success;
      case 'orange':
        return AppTheme.warning;
      case 'red':
        return AppTheme.error;
      case 'blue':
        return AppTheme.primaryBlue;
      default:
        return AppTheme.textTertiary;
    }
  }

  IconData _iconFromString(String iconString) {
    switch (iconString) {
      case 'check_circle':
        return Icons.check_circle;
      case 'warning':
        return Icons.warning;
      case 'error':
        return Icons.error;
      case 'dangerous':
        return Icons.dangerous;
      default:
        return Icons.info;
    }
  }
}
