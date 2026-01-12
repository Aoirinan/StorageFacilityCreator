import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../providers/late_logic_provider.dart';
import '../providers/auth_provider.dart';
import '../providers/tenant_provider.dart';
import '../providers/facility_provider.dart';
import '../models/facility_model.dart';
import '../widgets/badge_widget.dart';
import '../widgets/modern_page_wrapper.dart';
import '../theme/app_theme.dart';
import '../services/modern_navigation_service.dart';
import '../services/late_logic_service.dart';
import '../services/tenant_service.dart';
import '../models/payment_model.dart';
import '../models/tenant_model.dart';
import '../services/reminder_service.dart';
import '../models/reminder_model.dart';
import '../router/app_router.dart';
import '../router/app_route.dart';
import 'payment_detail_screen.dart';
import 'client_detail_screen.dart';
import 'facility_creation_wizard.dart';
import '../services/facility_creator_account_service.dart';

class LateDashboardScreen extends ConsumerStatefulWidget {
  const LateDashboardScreen({super.key});

  @override
  ConsumerState<LateDashboardScreen> createState() => _LateDashboardScreenState();
}

class _LateDashboardScreenState extends ConsumerState<LateDashboardScreen> {
  String _selectedFacilityId = '';

  @override
  void initState() {
    super.initState();
    _loadUserFacilities();
  }

  Future<void> _loadUserFacilities() async {
    final authState = ref.read(authStateProvider);
    if (authState.hasValue && authState.value != null) {
      try {
        // Ensure account exists before loading facilities
        await FacilityCreatorAccountService.getOrCreateAccountForCurrentUser();
        
        final facilitiesAsync = await ref.read(userFacilitiesProvider(authState.value!.uid).future);
        final facilities = facilitiesAsync as List<FacilityModel>? ?? <FacilityModel>[];
        if (facilities.isNotEmpty && mounted) {
          setState(() {
            _selectedFacilityId = facilities.first.id;
          });
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Error loading facilities: $e'),
              backgroundColor: AppTheme.error,
            ),
          );
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 4,
      child: ModernPageWrapper(
        currentRoute: '/delinquency',
        title: 'Delinquency',
        onNavigate: (route) {
          ModernNavigationService.navigateToRoute(context, route);
        },
        actions: [
          if (_selectedFacilityId.isNotEmpty) ...[
            IconButton(
              icon: const Icon(Icons.refresh),
              onPressed: () => _refreshData(),
              tooltip: 'Refresh',
            ),
            IconButton(
              icon: const Icon(Icons.money_off),
              onPressed: () => _applyLateFees(),
              tooltip: 'Apply Late Fees',
            ),
          ],
        ],
        child: _selectedFacilityId.isEmpty
            ? _buildNoFacilitiesMessage()
            : Column(
                children: [
                  Container(
                    color: AppTheme.surface,
                    child: const TabBar(
                      isScrollable: true,
                      tabs: [
                        Tab(text: 'Overview'),
                        Tab(text: 'Past Due'),
                        Tab(text: 'Reminders'),
                        Tab(text: 'Global DNR System'),
                      ],
                    ),
                  ),
                  Expanded(
                    child: TabBarView(
                      children: [
                        _buildDashboard(),
                        _buildPastDueTab(),
                        _buildRemindersTab(context),
                        _buildDnrTab(context),
                      ],
                    ),
                  ),
                ],
              ),
      ),
    );
  }

  Widget _buildNoFacilitiesMessage() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.business,
            size: 64,
            color: AppTheme.textTertiary,
          ),
          const SizedBox(height: 16),
          Text(
            'No Facilities Found',
            style: Theme.of(context).textTheme.headlineSmall,
          ),
          const SizedBox(height: 8),
          Text(
            'You must create a storage facility before managing late payments.',
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

  Widget _buildDashboard() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildFacilitySelector(),
          _buildStatistics(),
          const SizedBox(height: 24),
          _buildOverduePayments(),
          const SizedBox(height: 24),
          _buildTenantsWithOverdue(),
          const SizedBox(height: 24),
          _buildLateAlerts(),
        ],
      ),
    );
  }

  Widget _buildPastDueTab() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildFacilitySelector(),
          _buildOverduePayments(),
          const SizedBox(height: 24),
          _buildTenantsWithOverdue(),
        ],
      ),
    );
  }

  Widget _buildRemindersTab(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.notifications_outlined, size: 64, color: AppTheme.textTertiary),
          const SizedBox(height: 12),
          const Text('Reminders are managed in the Reminders module.'),
          const SizedBox(height: 12),
          ElevatedButton(
            onPressed: () => context.go('/reminders'),
            child: const Text('Open Reminders'),
          ),
        ],
      ),
    );
  }

  Widget _buildDnrTab(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.block_outlined, size: 64, color: AppTheme.textTertiary),
          const SizedBox(height: 12),
          const Text('Global DNR System is available in the DNR module.'),
          const SizedBox(height: 12),
          ElevatedButton(
            onPressed: () => context.go('/dnr'),
            child: const Text('Open DNR System'),
          ),
        ],
      ),
    );
  }

  Widget _buildStatistics() {
    return Consumer(
      builder: (context, ref, child) {
        return ref.watch(lateStatisticsProvider(_selectedFacilityId)).when(
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
                        child: _buildStatCard(
                          'Current',
                          '${stats['current'] ?? 0}',
                          AppTheme.success,
                          Icons.check_circle,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: _buildStatCard(
                          'Late',
                          '${stats['late'] ?? 0}',
                          AppTheme.warning,
                          Icons.warning,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: _buildStatCard(
                          'Overdue',
                          '${stats['overdue'] ?? 0}',
                          AppTheme.error,
                          Icons.error,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: _buildStatCard(
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
                        child: _buildStatCard(
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
          error: (error, stackTrace) => Center(
            child: Column(
              children: [
                Icon(Icons.error, color: AppTheme.error, size: 64),
                const SizedBox(height: 16),
                Text('Error loading statistics: $error'),
                const SizedBox(height: 16),
                ElevatedButton(
                  onPressed: () => ref.invalidate(lateStatisticsProvider(_selectedFacilityId)),
                  child: const Text('Retry'),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildFacilitySelector() {
    return Consumer(
      builder: (context, ref, child) {
        final auth = ref.watch(authStateProvider);
        return auth.when(
          data: (user) {
            if (user == null) return const SizedBox.shrink();
            final facilitiesAsync = ref.watch(userFacilitiesProvider(user.uid));
            return facilitiesAsync.when(
              data: (facilities) {
                if (facilities.isEmpty) {
                  return const SizedBox.shrink();
                }
                var currentId = _selectedFacilityId;
                if (currentId.isEmpty || !facilities.any((facility) => facility.id == currentId)) {
                  currentId = facilities.first.id;
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    if (mounted && _selectedFacilityId != currentId) {
                      setState(() => _selectedFacilityId = currentId);
                    }
                  });
                }

                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Facility',
                      style: Theme.of(context).textTheme.labelLarge,
                    ),
                    const SizedBox(height: 8),
                    DropdownButtonFormField<String>(
                      value: currentId.isEmpty ? null : currentId,
                      decoration: const InputDecoration(
                        border: OutlineInputBorder(),
                        prefixIcon: Icon(Icons.business),
                      ),
                      items: facilities
                          .map(
                            (facility) => DropdownMenuItem<String>(
                              value: facility.id,
                              child: Text(facility.name),
                            ),
                          )
                          .toList(),
                      onChanged: (value) {
                        if (value == null || value == _selectedFacilityId) return;
                        setState(() => _selectedFacilityId = value);
                        _refreshData();
                      },
                    ),
                    const SizedBox(height: 24),
                  ],
                );
              },
              loading: () => const Padding(
                padding: EdgeInsets.only(bottom: 24),
                child: LinearProgressIndicator(),
              ),
              error: (error, _) => const SizedBox.shrink(),
            );
          },
          loading: () => const SizedBox.shrink(),
          error: (_, __) => const SizedBox.shrink(),
        );
      },
    );
  }

  Widget _buildStatCard(String title, String value, Color color, IconData icon) {
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

  Widget _buildOverduePayments() {
    return Consumer(
      builder: (context, ref, child) {
        return ref.watch(overduePaymentsProvider(_selectedFacilityId)).when(
          data: (payments) => Card(
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
                        style: Theme.of(context).textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      Text(
                        '${payments.length} payments',
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: AppTheme.textSecondary,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  if (payments.isEmpty)
                    Center(
                      child: Column(
                        children: [
                          Icon(Icons.check_circle, color: AppTheme.success, size: 64),
                          const SizedBox(height: 16),
                          Text(
                            'No overdue payments',
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                        ],
                      ),
                    )
                  else
                    ListView.builder(
                      shrinkWrap: true,
                      physics: const NeverScrollableScrollPhysics(),
                      itemCount: payments.length,
                      itemBuilder: (context, index) {
                        final payment = payments[index];
                        return _buildPaymentCard(payment);
                      },
                    ),
                ],
              ),
            ),
          ),
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (error, stackTrace) => Center(
            child: Text('Error loading overdue payments: $error'),
          ),
        );
      },
    );
  }

  Widget _buildPaymentCard(PaymentModel payment) {
    final badgeInfo = ref.read(paymentBadgeProvider(payment));
    final lateFee = LateLogicService.calculateLateFee(payment);

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: _getColorFromString(badgeInfo.color),
          child: Icon(
            _getIconFromString(badgeInfo.icon),
            color: AppTheme.textOnDark,
          ),
        ),
        title: Text(
          '\$${payment.amount.toStringAsFixed(2)}',
          style: const TextStyle(fontWeight: FontWeight.bold),
        ),
        subtitle: FutureBuilder<String?>(
          future: _getTenantUnitNumber(payment.tenantId),
          builder: (context, snapshot) {
            final unitNumber = snapshot.data;
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (unitNumber != null && unitNumber.isNotEmpty)
                  Text(
                    'Unit: $unitNumber',
                    style: const TextStyle(fontWeight: FontWeight.w600, color: AppTheme.primaryBlue),
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
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              icon: const Icon(Icons.send),
              tooltip: 'Send Reminder',
              onPressed: () => _sendPaymentReminder(payment),
              color: AppTheme.primaryBlue,
            ),
            BadgeWidget(badgeInfo: badgeInfo),
          ],
        ),
        onTap: () => _navigateToPaymentDetail(payment),
      ),
    );
  }

  Future<void> _sendPaymentReminder(PaymentModel payment) async {
    try {
      // Get tenant info
      final tenant = await TenantService.getTenantById(_selectedFacilityId, payment.tenantId);
      if (tenant == null) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Tenant not found')),
          );
        }
        return;
      }

      // Create reminder
      final reminder = await ReminderService.createReminder(
        facilityId: _selectedFacilityId,
        tenantId: payment.tenantId,
        type: ReminderType.rentOverdue,
        title: 'Payment Overdue Reminder',
        message: 'Your payment of \$${payment.amount.toStringAsFixed(2)} was due on ${_formatDate(payment.dueDate)} and is now ${payment.daysOverdue} days overdue. Please make payment as soon as possible.',
        scheduledFor: DateTime.now(),
        channels: [ReminderChannel.email],
        paymentId: payment.id,
        contractId: payment.contractId,
        tenantEmail: tenant.email,
        tenantPhone: tenant.phone,
      );

      // Send reminder immediately
      final sent = await ReminderService.sendReminder(
        facilityId: _selectedFacilityId,
        reminderId: reminder.id,
        tenantEmail: tenant.email ?? '',
        tenantPhone: tenant.phone ?? '',
        message: 'Your payment of \$${payment.amount.toStringAsFixed(2)} was due on ${_formatDate(payment.dueDate)} and is now ${payment.daysOverdue} days overdue. Please make payment as soon as possible.',
        channels: [ReminderChannel.email],
      );

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(sent ? 'Reminder sent successfully' : 'Failed to send reminder'),
            backgroundColor: sent ? AppTheme.success : AppTheme.error,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error sending reminder: $e')),
        );
      }
    }
  }

  Widget _buildTenantsWithOverdue() {
    return Consumer(
      builder: (context, ref, child) {
        return ref.watch(tenantsWithOverdueProvider(_selectedFacilityId)).when(
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
                          Icon(Icons.check_circle, color: AppTheme.success, size: 64),
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
                        final tenant = tenants[index];
                        return _buildTenantCard(tenant);
                      },
                    ),
                ],
              ),
            ),
          ),
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (error, stackTrace) => Center(
            child: Text('Error loading tenants: $error'),
          ),
        );
      },
    );
  }

  Widget _buildTenantCard(TenantOverdueInfo tenantInfo) {
    final badgeInfo = LateLogicService.getTenantBadge(tenantInfo.status);
    final balanceText = 'Balance: \$${tenantInfo.totalBalance.toStringAsFixed(2)}';
    final baseText = 'Payments overdue: ${tenantInfo.overduePayments}';
    final lateFeesText = tenantInfo.totalLateFees > 0
        ? 'Late fees: \$${tenantInfo.totalLateFees.toStringAsFixed(2)}'
        : null;
    final longestOverdueText = tenantInfo.maxDaysOverdue > 0
        ? LateLogicService.formatDaysOverdue(tenantInfo.maxDaysOverdue)
        : null;

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: _getColorFromString(badgeInfo.color),
          child: Icon(
            _getIconFromString(badgeInfo.icon),
            color: Colors.white,
          ),
        ),
        title: Text(tenantInfo.tenant.name),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(tenantInfo.tenant.email?.isNotEmpty == true ? tenantInfo.tenant.email! : 'No email on file'),
            if (tenantInfo.tenant.unitNumber.isNotEmpty)
              Text(
                'Unit: ${tenantInfo.tenant.unitNumber}',
                style: const TextStyle(fontWeight: FontWeight.w600, color: AppTheme.primaryBlue),
              ),
            const SizedBox(height: 4),
            Text(balanceText, style: const TextStyle(fontWeight: FontWeight.w600)),
            Text(baseText),
            if (lateFeesText != null) Text(lateFeesText),
            if (longestOverdueText != null) Text(longestOverdueText),
          ],
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              icon: const Icon(Icons.send),
              tooltip: 'Send Reminder',
              onPressed: () => _sendTenantReminder(tenantInfo),
              color: AppTheme.primaryBlue,
            ),
            BadgeWidget(badgeInfo: badgeInfo),
          ],
        ),
        onTap: () => _navigateToTenantDetail(tenantInfo.tenant),
      ),
    );
  }

  Future<String?> _getTenantUnitNumber(String tenantId) async {
    try {
      final tenant = await TenantService.getTenantById(_selectedFacilityId, tenantId);
      return tenant?.unitNumber;
    } catch (e) {
      return null;
    }
  }

  Future<void> _sendTenantReminder(TenantOverdueInfo tenantInfo) async {
    try {
      final tenant = tenantInfo.tenant;
      final message = 'You have ${tenantInfo.overduePayments} overdue payment(s) totaling \$${tenantInfo.totalBalance.toStringAsFixed(2)}. Please make payment as soon as possible.';

      // Create reminder
      final reminder = await ReminderService.createReminder(
        facilityId: _selectedFacilityId,
        tenantId: tenant.id,
        type: ReminderType.rentOverdue,
        title: 'Overdue Payment Reminder',
        message: message,
        scheduledFor: DateTime.now(),
        channels: [ReminderChannel.email],
        tenantEmail: tenant.email,
        tenantPhone: tenant.phone,
      );

      // Send reminder immediately
      final sent = await ReminderService.sendReminder(
        facilityId: _selectedFacilityId,
        reminderId: reminder.id,
        tenantEmail: tenant.email ?? '',
        tenantPhone: tenant.phone ?? '',
        message: message,
        channels: [ReminderChannel.email],
      );

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(sent ? 'Reminder sent successfully' : 'Failed to send reminder'),
            backgroundColor: sent ? AppTheme.success : AppTheme.error,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error sending reminder: $e')),
        );
      }
    }
  }

  Widget _buildLateAlerts() {
    return Consumer(
      builder: (context, ref, child) {
        return ref.watch(lateAlertsProvider(_selectedFacilityId)).when(
          data: (alerts) => Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Late Alerts',
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 16),
                  if (alerts.isEmpty)
                    Center(
                      child: Column(
                        children: [
                          Icon(Icons.check_circle, color: AppTheme.success, size: 64),
                          const SizedBox(height: 16),
                          Text(
                            'No late alerts',
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                        ],
                      ),
                    )
                  else
                    ListView.builder(
                      shrinkWrap: true,
                      physics: const NeverScrollableScrollPhysics(),
                      itemCount: alerts.length,
                      itemBuilder: (context, index) {
                        final alert = alerts[index];
                        return _buildAlertCard(alert);
                      },
                    ),
                ],
              ),
            ),
          ),
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (error, stackTrace) => Center(
            child: Text('Error loading alerts: $error'),
          ),
        );
      },
    );
  }

  Widget _buildAlertCard(LateAlert alert) {
    final color = _getAlertColor(alert.severity);
    final icon = _getAlertIcon(alert.severity);

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: color,
          child: Icon(icon, color: AppTheme.textOnDark),
        ),
        title: Text(alert.title),
        subtitle: Text(alert.message),
        trailing: _buildSeverityBadge(alert.severity),
      ),
    );
  }

  Widget _buildSeverityBadge(LateAlertSeverity severity) {
    final color = _getAlertColor(severity);
    final label = severity.name.toUpperCase();

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withOpacity(0.1),
        border: Border.all(color: color),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontSize: 10,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }

  Color _getAlertColor(LateAlertSeverity severity) {
    switch (severity) {
      case LateAlertSeverity.low:
        return AppTheme.success;
      case LateAlertSeverity.medium:
        return AppTheme.warning;
      case LateAlertSeverity.high:
        return AppTheme.error;
      case LateAlertSeverity.critical:
        return AppTheme.error;
    }
  }

  IconData _getAlertIcon(LateAlertSeverity severity) {
    switch (severity) {
      case LateAlertSeverity.low:
        return Icons.info;
      case LateAlertSeverity.medium:
        return Icons.warning;
      case LateAlertSeverity.high:
        return Icons.error;
      case LateAlertSeverity.critical:
        return Icons.dangerous;
    }
  }

  Color _getColorFromString(String colorString) {
    switch (colorString.toLowerCase()) {
      case 'green':
        return AppTheme.success;
      case 'orange':
        return AppTheme.warning;
      case 'red':
        return AppTheme.error;
      case 'blue':
        return AppTheme.primaryBlue;
      case 'purple':
        return Colors.purple; // Keep as is for badge variety
      case 'teal':
        return Colors.teal; // Keep as is for badge variety
      case 'amber':
        return Colors.amber; // Keep as is for badge variety
      case 'indigo':
        return Colors.indigo; // Keep as is for badge variety
      default:
        return AppTheme.textTertiary;
    }
  }

  IconData _getIconFromString(String iconString) {
    switch (iconString) {
      case 'check_circle':
        return Icons.check_circle;
      case 'warning':
        return Icons.warning;
      case 'error':
        return Icons.error;
      case 'dangerous':
        return Icons.dangerous;
      case 'info':
        return Icons.info;
      case 'star':
        return Icons.star;
      case 'schedule':
        return Icons.schedule;
      case 'payment':
        return Icons.payment;
      case 'description':
        return Icons.description;
      case 'business':
        return Icons.business;
      case 'people':
        return Icons.people;
      default:
        return Icons.info;
    }
  }

  String _formatDate(DateTime date) {
    return '${date.month}/${date.day}/${date.year}';
  }

  void _navigateToPaymentDetail(PaymentModel payment) {
    context.push(AppRoute.paymentDetail, extra: payment);
  }

  void _navigateToTenantDetail(TenantModel tenant) {
    context.push(AppRoute.tenantDetail, extra: tenant);
  }

  void _refreshData() {
    ref.invalidate(lateStatisticsProvider(_selectedFacilityId));
    ref.invalidate(overduePaymentsProvider(_selectedFacilityId));
    ref.invalidate(tenantsWithOverdueProvider(_selectedFacilityId));
    ref.invalidate(lateAlertsProvider(_selectedFacilityId));
  }

  void _applyLateFees() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Apply Late Fees'),
        content: const Text('This will apply late fees to all overdue payments. Continue?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () async {
              Navigator.of(context).pop();
              await ref.read(lateLogicOperationsProvider.notifier).applyLateFees(_selectedFacilityId);
              _refreshData();
            },
            child: const Text('Apply'),
          ),
        ],
      ),
    );
  }
}
