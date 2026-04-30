import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../providers/late_logic_provider.dart';
import '../providers/auth_provider.dart';
import '../providers/tenant_provider.dart';
import '../providers/facility_provider.dart';
import '../providers/active_facility_provider.dart';
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
import '../providers/reminder_provider.dart';
import '../router/app_router.dart';
import '../router/app_route.dart';
import 'payment_detail_screen.dart';
import 'client_detail_screen.dart';
import 'facility_creation_wizard.dart';
import '../services/facility_creator_account_service.dart';
import 'reminder_list_screen.dart';
import 'dnr_list_screen.dart';
import 'facility_edit_screen.dart';

class LateDashboardScreen extends ConsumerStatefulWidget {
  const LateDashboardScreen({super.key});

  @override
  ConsumerState<LateDashboardScreen> createState() => _LateDashboardScreenState();
}

class _LateDashboardScreenState extends ConsumerState<LateDashboardScreen> with SingleTickerProviderStateMixin {
  String? _selectedFacilityId; // Changed to nullable to match Yield pattern
  late TabController _tabController;
  int _previousTabIndex = 0;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 4, vsync: this);
    _tabController.addListener(_handleTabChange);
    _loadUserFacilities();
  }

  @override
  void dispose() {
    _tabController.removeListener(_handleTabChange);
    _tabController.dispose();
    super.dispose();
  }

  void _handleTabChange() {
    final currentIndex = _tabController.index;
    
    // DO NOT navigate away when tabs are clicked
    // Show content inline in the tab instead
    // Just update the previous tab index for reference
    _previousTabIndex = currentIndex;
    
    // Removed navigation logic - tabs now show content inline
  }

  Future<void> _loadUserFacilities() async {
    final authState = ref.read(authStateProvider);
    if (authState.hasValue && authState.value != null) {
      try {
        // Ensure account exists before loading facilities
        await FacilityCreatorAccountService.getOrCreateAccountForCurrentUser();
        ref.invalidate(userFacilitiesProvider(authState.value!.uid));
        final facilitiesAsync = await ref.read(userFacilitiesProvider(authState.value!.uid).future);
        final facilities = facilitiesAsync as List<FacilityModel>? ?? <FacilityModel>[];
        if (facilities.isNotEmpty && mounted) {
          // Use active facility (same as dashboard) so Delinquency stays in sync when navigating back
          final activeId = ref.read(activeFacilityIdProvider).whenOrNull(data: (d) => d);
          final id = activeId != null && facilities.any((f) => f.id == activeId)
              ? activeId
              : facilities.first.id;
          setState(() {
            _selectedFacilityId = id;
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
    // When _selectedFacilityId is null (e.g. after navigating back), use active facility
    // so we don't flash "No Facilities Found" and stay in sync with dashboard.
    return Consumer(
      builder: (context, ref, _) {
        final auth = ref.watch(authStateProvider);
        final activeId = ref.watch(activeFacilityIdProvider).whenOrNull(data: (d) => d);
        final facilities = auth.whenOrNull(data: (d) => d) != null
            ? ref.watch(userFacilitiesProvider(auth.whenOrNull(data: (d) => d)!.uid)).whenOrNull(data: (d) => d)
            : null;

        ref.listen(activeFacilityIdProvider, (prev, next) {
          final nextId = next.whenOrNull(data: (d) => d);
          if (nextId != null && facilities != null && facilities.any((f) => f.id == nextId) &&
              _selectedFacilityId != nextId && mounted) {
            setState(() => _selectedFacilityId = nextId);
          }
        });

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
          return _buildNoFacilitiesMessage();
        }

        final facilityId = effectiveId;
        final colorScheme = Theme.of(context).colorScheme;
        return Column(
          children: [
            Container(
              color: colorScheme.surface,
              child: TabBar(
                controller: _tabController,
                isScrollable: true,
                tabs: const [
                  Tab(text: 'Overview'),
                  Tab(text: 'Past Due'),
                  Tab(text: 'Reminders'),
                  Tab(text: 'Global DNR System'),
                ],
              ),
            ),
            Expanded(
              child: TabBarView(
                controller: _tabController,
                physics: const NeverScrollableScrollPhysics(),
                children: [
                  _buildDashboard(facilityId),
                  _buildPastDueTab(facilityId),
                  _buildRemindersTab(context, facilityId),
                  _buildDnrTab(context),
                ],
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildHowLateWorks(String facilityId, FacilityModel? facility) {
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
            'A tenant is marked late when their paid-through date is before the start of the current month minus your grace period. You can set the grace period and late fee in Facility → Billing settings.',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: colorScheme.onSurfaceVariant,
            ),
          ),
          if (facility != null) ...[
            const SizedBox(height: 10),
            TextButton.icon(
              onPressed: () {
                context.push(AppRoute.legacyScreen, extra: FacilityEditScreen(facility: facility));
              },
              icon: const Icon(Icons.settings, size: 18),
              label: const Text('Edit grace period & late fees'),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildNoFacilitiesMessage() {
    final colorScheme = Theme.of(context).colorScheme;
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.business,
            size: 64,
            color: colorScheme.onSurfaceVariant,
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

  Widget _buildDashboard(String facilityId) {
    final facilityAsync = ref.watch(facilityProvider(facilityId));
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildHowLateWorks(facilityId, facilityAsync.whenOrNull(data: (d) => d)),
          const SizedBox(height: 16),
          _buildStatistics(facilityId),
          const SizedBox(height: 24),
          _buildOverduePayments(facilityId),
          const SizedBox(height: 24),
          _buildTenantsWithOverdue(facilityId),
          const SizedBox(height: 24),
          _buildLateAlerts(facilityId),
        ],
      ),
    );
  }

  Widget _buildPastDueTab(String facilityId) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildOverduePayments(facilityId),
          const SizedBox(height: 24),
          _buildTenantsWithOverdue(facilityId),
        ],
      ),
    );
  }

  // ── Reminders tab state ──────────────────────────────────────────────────
  String _reminderSearch = '';
  ReminderType? _reminderTypeFilter;
  ReminderStatus? _reminderStatusFilter;

  Widget _buildRemindersTab(BuildContext context, String facilityId) {
    final colorScheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // ── Header bar ──────────────────────────────────────────────────
        Container(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Payment Reminders',
                      style: Theme.of(context).textTheme.titleLarge?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'Manage and automate payment reminders for this facility',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: colorScheme.onSurfaceVariant,
                          ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              OutlinedButton.icon(
                onPressed: () => _navigateToReminderSchedules(facilityId),
                icon: const Icon(Icons.schedule, size: 16),
                label: const Text('Schedules'),
                style: OutlinedButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                ),
              ),
              const SizedBox(width: 8),
              FilledButton.icon(
                onPressed: () => _navigateToCreateReminder(facilityId),
                icon: const Icon(Icons.add, size: 16),
                label: const Text('New Reminder'),
                style: FilledButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        // ── Stats row ────────────────────────────────────────────────────
        _buildReminderStats(facilityId),
        const SizedBox(height: 12),
        // ── Filters ──────────────────────────────────────────────────────
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  decoration: InputDecoration(
                    hintText: 'Search reminders…',
                    prefixIcon: const Icon(Icons.search, size: 18),
                    isDense: true,
                    contentPadding: const EdgeInsets.symmetric(vertical: 10),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                  onChanged: (v) => setState(() => _reminderSearch = v),
                ),
              ),
              const SizedBox(width: 10),
              DropdownButtonHideUnderline(
                child: DropdownButton<ReminderType?>(
                  value: _reminderTypeFilter,
                  hint: const Text('All Types'),
                  isDense: true,
                  borderRadius: BorderRadius.circular(8),
                  items: [
                    const DropdownMenuItem(value: null, child: Text('All Types')),
                    ...ReminderType.values.map((t) => DropdownMenuItem(
                          value: t,
                          child: Text(t.displayName),
                        )),
                  ],
                  onChanged: (v) => setState(() => _reminderTypeFilter = v),
                ),
              ),
              const SizedBox(width: 10),
              DropdownButtonHideUnderline(
                child: DropdownButton<ReminderStatus?>(
                  value: _reminderStatusFilter,
                  hint: const Text('All Status'),
                  isDense: true,
                  borderRadius: BorderRadius.circular(8),
                  items: [
                    const DropdownMenuItem(value: null, child: Text('All Status')),
                    ...ReminderStatus.values.map((s) => DropdownMenuItem(
                          value: s,
                          child: Text(s.displayName),
                        )),
                  ],
                  onChanged: (v) => setState(() => _reminderStatusFilter = v),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        Divider(height: 1, color: colorScheme.outlineVariant),
        // ── List ─────────────────────────────────────────────────────────
        Expanded(
          child: _buildReminderList(context, facilityId),
        ),
      ],
    );
  }

  Widget _buildReminderStats(String facilityId) {
    return Consumer(
      builder: (context, ref, _) {
        return ref.watch(reminderStatsProvider(facilityId)).when(
          data: (stats) => Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                _buildReminderStatChip('Total', stats['total'] ?? 0, null),
                const SizedBox(width: 8),
                _buildReminderStatChip('Pending', stats['pending'] ?? 0, AppTheme.warning),
                const SizedBox(width: 8),
                _buildReminderStatChip('Sent', stats['sent'] ?? 0, AppTheme.success),
                const SizedBox(width: 8),
                _buildReminderStatChip('Overdue', stats['overdue'] ?? 0, AppTheme.error),
              ],
            ),
          ),
          loading: () => const SizedBox(height: 40, child: Center(child: LinearProgressIndicator())),
          error: (_, __) => const SizedBox.shrink(),
        );
      },
    );
  }

  Widget _buildReminderStatChip(String label, int count, Color? color) {
    final colorScheme = Theme.of(context).colorScheme;
    final effectiveColor = color ?? colorScheme.primary;
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 12),
        decoration: BoxDecoration(
          color: effectiveColor.withOpacity(0.08),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: effectiveColor.withOpacity(0.25)),
        ),
        child: Column(
          children: [
            Text(
              '$count',
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.w700,
                color: effectiveColor,
              ),
            ),
            Text(
              label,
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                  ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildReminderList(BuildContext context, String facilityId) {
    return Consumer(
      builder: (context, ref, _) {
        return ref.watch(reminderListProvider(facilityId)).when(
          data: (reminders) {
            final filtered = reminders.where((r) {
              if (_reminderTypeFilter != null && r.type != _reminderTypeFilter) return false;
              if (_reminderStatusFilter != null && r.status != _reminderStatusFilter) return false;
              if (_reminderSearch.isNotEmpty) {
                final q = _reminderSearch.toLowerCase();
                if (!r.title.toLowerCase().contains(q) &&
                    !r.message.toLowerCase().contains(q)) return false;
              }
              return true;
            }).toList();

            if (filtered.isEmpty) {
              return Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.notifications_none,
                        size: 56, color: Theme.of(context).colorScheme.outlineVariant),
                    const SizedBox(height: 12),
                    Text('No reminders found',
                        style: Theme.of(context).textTheme.titleMedium),
                    const SizedBox(height: 6),
                    Text(
                      reminders.isEmpty
                          ? 'Create your first reminder using the button above.'
                          : 'Try adjusting your filters.',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: Theme.of(context).colorScheme.onSurfaceVariant,
                          ),
                      textAlign: TextAlign.center,
                    ),
                    if (reminders.isEmpty) ...[
                      const SizedBox(height: 16),
                      FilledButton.icon(
                        onPressed: () => _navigateToCreateReminder(facilityId),
                        icon: const Icon(Icons.add),
                        label: const Text('Create Reminder'),
                      ),
                    ],
                  ],
                ),
              );
            }

            return ListView.separated(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
              itemCount: filtered.length,
              separatorBuilder: (_, __) => const SizedBox(height: 6),
              itemBuilder: (context, index) =>
                  _buildInlineReminderCard(context, filtered[index], facilityId),
            );
          },
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (err, _) => Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.error_outline,
                    size: 48, color: AppTheme.error),
                const SizedBox(height: 12),
                Text('Error loading reminders',
                    style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 6),
                Text(err.toString(),
                    style: Theme.of(context).textTheme.bodySmall,
                    textAlign: TextAlign.center),
                const SizedBox(height: 16),
                OutlinedButton(
                  onPressed: () => ref.invalidate(reminderListProvider(facilityId)),
                  child: const Text('Retry'),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildInlineReminderCard(
      BuildContext context, ReminderModel reminder, String facilityId) {
    final colorScheme = Theme.of(context).colorScheme;
    Color statusColor;
    IconData statusIcon;
    switch (reminder.status) {
      case ReminderStatus.pending:
        statusColor = AppTheme.warning;
        statusIcon = Icons.schedule;
        break;
      case ReminderStatus.sent:
        statusColor = AppTheme.success;
        statusIcon = Icons.check_circle_outline;
        break;
      case ReminderStatus.failed:
        statusColor = AppTheme.error;
        statusIcon = Icons.error_outline;
        break;
      case ReminderStatus.cancelled:
        statusColor = colorScheme.outlineVariant;
        statusIcon = Icons.cancel_outlined;
        break;
    }

    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(color: colorScheme.outlineVariant),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: () => _navigateToReminderDetail(reminder, facilityId),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: statusColor.withOpacity(0.12),
                  shape: BoxShape.circle,
                ),
                child: Icon(statusIcon, size: 18, color: statusColor),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      reminder.title,
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      reminder.message,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: colorScheme.onSurfaceVariant,
                          ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 4),
                    Wrap(
                      spacing: 6,
                      children: [
                        _reminderChip(reminder.type.displayName, colorScheme.primary),
                        _reminderChip(reminder.statusDisplayName, statusColor),
                        _reminderChip(
                          '${reminder.scheduledFor.month}/${reminder.scheduledFor.day}/${reminder.scheduledFor.year}',
                          colorScheme.onSurfaceVariant,
                        ),
                        if (reminder.isOverdue)
                          _reminderChip(
                              '${reminder.daysUntilDue}d overdue', AppTheme.error),
                      ],
                    ),
                  ],
                ),
              ),
              if (reminder.status == ReminderStatus.pending) ...[
                IconButton(
                  icon: const Icon(Icons.send, size: 18),
                  tooltip: 'Send now',
                  onPressed: () => _sendReminderInline(reminder, facilityId),
                  color: colorScheme.primary,
                  visualDensity: VisualDensity.compact,
                ),
              ],
              Icon(Icons.chevron_right,
                  size: 18, color: colorScheme.onSurfaceVariant),
            ],
          ),
        ),
      ),
    );
  }

  Widget _reminderChip(String label, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withOpacity(0.1),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        label,
        style: TextStyle(fontSize: 10, color: color, fontWeight: FontWeight.w500),
      ),
    );
  }

  void _navigateToCreateReminder(String facilityId) {
    context.push('${AppRoute.reminderCreate}?facilityId=$facilityId').then((_) {
      if (mounted) {
        ref.invalidate(reminderListProvider(facilityId));
        ref.invalidate(reminderStatsProvider(facilityId));
      }
    });
  }

  void _navigateToReminderDetail(ReminderModel reminder, String facilityId) {
    context.push(AppRoute.reminderDetail, extra: reminder).then((_) {
      if (mounted) {
        ref.invalidate(reminderListProvider(facilityId));
        ref.invalidate(reminderStatsProvider(facilityId));
      }
    });
  }

  void _navigateToReminderSchedules(String facilityId) {
    // Get facility name for the schedule screen
    final auth = ref.read(authStateProvider);
    final uid = auth.whenOrNull(data: (u) => u?.uid) ?? '';
    final facilities = uid.isNotEmpty
        ? ref.read(userFacilitiesProvider(uid)).whenOrNull(data: (d) => d)
        : null;
    final facilityName = facilities
            ?.firstWhere((f) => f.id == facilityId,
                orElse: () => facilities.first)
            .name ??
        'Facility';
    context.push(
      '${AppRoute.reminderSchedule}?facilityId=$facilityId&facilityName=${Uri.encodeComponent(facilityName)}',
    );
  }

  void _sendReminderInline(ReminderModel reminder, String facilityId) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Send Reminder'),
        content: Text('Send "${reminder.title}" now?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () async {
              Navigator.of(ctx).pop();
              await ref.read(reminderOperationsProvider.notifier).sendReminder(
                    facilityId: reminder.facilityId,
                    reminderId: reminder.id,
                    tenantEmail: reminder.tenantEmail ?? '',
                    tenantPhone: reminder.tenantPhone ?? '',
                    message: reminder.message,
                    channels: reminder.channels,
                  );
              if (mounted) {
                ref.invalidate(reminderListProvider(facilityId));
                ref.invalidate(reminderStatsProvider(facilityId));
              }
            },
            child: const Text('Send'),
          ),
        ],
      ),
    );
  }

  Widget _buildDnrTab(BuildContext context) {
    // Show DNR info inline - no full navigation
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Global DNR System',
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 8),
          Text(
            'Do Not Rent list - shared across all facilities',
            style: TextStyle(color: AppTheme.textSecondary),
          ),
          const SizedBox(height: 16),
          const Text(
            'The Global DNR System is available via the dedicated DNR menu.',
            style: TextStyle(fontSize: 14),
          ),
          const SizedBox(height: 16),
          ElevatedButton.icon(
            onPressed: () {
              // This navigates to dedicated DNR page
              context.push('/dnr');
            },
            icon: const Icon(Icons.block),
            label: const Text('Manage DNR List'),
          ),
        ],
      ),
    );
  }

  Widget _buildStatistics(String facilityId) {
    return Consumer(
      builder: (context, ref, child) {
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
                  onPressed: () => ref.invalidate(lateStatisticsProvider(facilityId)),
                  child: const Text('Retry'),
                ),
              ],
            ),
          ),
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

  Widget _buildOverduePayments(String facilityId) {
    return Consumer(
      builder: (context, ref, child) {
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
                              style: Theme.of(context).textTheme.titleLarge?.copyWith(
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            Text(
                              countLabel,
                              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                                color: hasOverdueByPayments || hasOverdueByTenants
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
                              final payment = payments[index];
                              return _buildPaymentCard(payment, facilityId);
                            },
                          )
                        else if (tenantsWithOverdue.isNotEmpty)
                          Center(
                            child: Column(
                              children: [
                                Icon(Icons.warning_amber_rounded, color: AppTheme.warning, size: 64),
                                const SizedBox(height: 16),
                                Text(
                                  '${tenantsWithOverdue.length} tenant(s) with overdue balance',
                                  style: Theme.of(context).textTheme.titleMedium,
                                  textAlign: TextAlign.center,
                                ),
                                const SizedBox(height: 8),
                                Text(
                                  'See "Tenants with Overdue Payments" below for details.',
                                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                                    color: AppTheme.textSecondary,
                                  ),
                                  textAlign: TextAlign.center,
                                ),
                              ],
                            ),
                          )
                        else
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
                          ),
                      ],
                    ),
                  ),
                );
              },
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (error, _) => Center(
                child: Text('Error loading tenants: $error'),
              ),
            );
          },
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (error, stackTrace) => Center(
            child: Text('Error loading overdue payments: $error'),
          ),
        );
      },
    );
  }

  Widget _buildPaymentCard(PaymentModel payment, String facilityId) {
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
          future: _getTenantUnitNumber(payment.tenantId, facilityId),
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
              onPressed: () => _sendPaymentReminder(payment, facilityId),
              color: AppTheme.primaryBlue,
            ),
            BadgeWidget(badgeInfo: badgeInfo),
          ],
        ),
        onTap: () => _navigateToPaymentDetail(payment, facilityId),
      ),
    );
  }

  Future<void> _sendPaymentReminder(PaymentModel payment, String facilityId) async {
    try {
      // Get tenant info
      final tenant = await TenantService.getTenantById(facilityId, payment.tenantId);
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
        facilityId: facilityId,
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
        facilityId: _selectedFacilityId!,
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

  Widget _buildTenantsWithOverdue(String facilityId) {
    return Consumer(
      builder: (context, ref, child) {
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
                        return _buildTenantCard(tenant, facilityId);
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

  Widget _buildTenantCard(TenantOverdueInfo tenantInfo, String facilityId) {
    final badgeInfo = LateLogicService.getTenantBadge(tenantInfo.status);
    final balanceText = 'Balance: \$${tenantInfo.totalBalance.toStringAsFixed(2)}';
    final hasBalanceDue = tenantInfo.totalBalance > 0;
    final baseText = tenantInfo.overduePayments > 0
        ? 'Payments overdue: ${tenantInfo.overduePayments}'
        : hasBalanceDue
            ? 'Balance due (past due)'
            : 'Payments overdue: 0';
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
              onPressed: () => _sendTenantReminder(tenantInfo, facilityId),
              color: AppTheme.primaryBlue,
            ),
            BadgeWidget(badgeInfo: badgeInfo),
          ],
        ),
        onTap: () => _navigateToTenantDetail(tenantInfo.tenant, facilityId),
      ),
    );
  }

  Future<String?> _getTenantUnitNumber(String tenantId, String facilityId) async {
    try {
      final tenant = await TenantService.getTenantById(facilityId, tenantId);
      return tenant?.unitNumber;
    } catch (e) {
      return null;
    }
  }

  Future<void> _sendTenantReminder(TenantOverdueInfo tenantInfo, String facilityId) async {
    try {
      final tenant = tenantInfo.tenant;
      final paymentCount = tenantInfo.overduePayments > 0 ? tenantInfo.overduePayments : 1;
      final message = 'You have $paymentCount overdue payment(s) totaling \$${tenantInfo.totalBalance.toStringAsFixed(2)}. Please make payment as soon as possible.';

      // Create reminder
      final reminder = await ReminderService.createReminder(
        facilityId: facilityId,
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
        facilityId: facilityId,
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

  Widget _buildLateAlerts(String facilityId) {
    return Consumer(
      builder: (context, ref, child) {
        return ref.watch(lateAlertsProvider(facilityId)).when(
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

  void _navigateToPaymentDetail(PaymentModel payment, String facilityId) {
    context.push(AppRoute.paymentDetail, extra: payment);
  }

  void _navigateToTenantDetail(TenantModel tenant, String facilityId) {
    context.push(AppRoute.tenantDetail, extra: tenant);
  }

  void _refreshData() {
    if (_selectedFacilityId == null) return;
    ref.invalidate(lateStatisticsProvider(_selectedFacilityId!));
    ref.invalidate(overduePaymentsProvider(_selectedFacilityId!));
    ref.invalidate(tenantsWithOverdueProvider(_selectedFacilityId!));
    ref.invalidate(lateAlertsProvider(_selectedFacilityId!));
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
              await ref.read(lateLogicOperationsProvider.notifier).applyLateFees(_selectedFacilityId!);
              _refreshData();
            },
            child: const Text('Apply'),
          ),
        ],
      ),
    );
  }
}
