import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:sfcapp/models/reminder_model.dart';
import 'package:sfcapp/providers/active_facility_provider.dart';
import 'package:sfcapp/providers/auth_provider.dart';
import 'package:sfcapp/providers/facility_provider.dart';
import 'package:sfcapp/providers/reminder_provider.dart';
import 'package:sfcapp/router/app_route.dart';
import 'package:sfcapp/theme/app_theme.dart';

class ReminderListScreen extends ConsumerStatefulWidget {
  const ReminderListScreen({super.key});

  @override
  ConsumerState<ReminderListScreen> createState() => _ReminderListScreenState();
}

class _ReminderListScreenState extends ConsumerState<ReminderListScreen> {
  String _searchQuery = '';
  ReminderType? _typeFilter;
  ReminderStatus? _statusFilter;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    final authAsync = ref.watch(authStateProvider);
    final uid = authAsync.whenOrNull(data: (u) => u?.uid) ?? '';

    final facilitiesAsync = uid.isNotEmpty
        ? ref.watch(userFacilitiesProvider(uid))
        : const AsyncValue<dynamic>.loading();

    final activeIdAsync = ref.watch(activeFacilityIdProvider);

    return facilitiesAsync.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(child: Text('Error loading facilities: $e')),
      data: (facilitiesRaw) {
        final facilities =
            (facilitiesRaw as List?)?.cast<dynamic>().toList() ?? [];
        if (facilities.isEmpty) {
          return _buildNoFacilities();
        }

        final activeId = activeIdAsync.whenOrNull(data: (d) => d);
        final facilityId = (activeId != null &&
                facilities.any((f) => (f as dynamic).id == activeId))
            ? activeId
            : (facilities.first as dynamic).id as String;

        final facilityName = (facilities.firstWhere(
              (f) => (f as dynamic).id == facilityId,
              orElse: () => facilities.first,
            ) as dynamic)
            .name as String;

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ── Header ──────────────────────────────────────────────────
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
                          style:
                              Theme.of(context).textTheme.titleLarge?.copyWith(
                                    fontWeight: FontWeight.w700,
                                  ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          facilityName,
                          style:
                              Theme.of(context).textTheme.bodySmall?.copyWith(
                                    color: colorScheme.onSurfaceVariant,
                                  ),
                        ),
                      ],
                    ),
                  ),
                  // Facility selector
                  DropdownButtonHideUnderline(
                    child: DropdownButton<String>(
                      value: facilityId,
                      isDense: true,
                      borderRadius: BorderRadius.circular(8),
                      items: facilities
                          .map((f) => DropdownMenuItem<String>(
                                value: (f as dynamic).id as String,
                                child: Text((f as dynamic).name as String),
                              ))
                          .toList(),
                      onChanged: (id) {
                        if (id != null) {
                          ref
                              .read(activeFacilityIdProvider.notifier)
                              .setActiveFacilityId(id);
                        }
                      },
                    ),
                  ),
                  const SizedBox(width: 8),
                  OutlinedButton.icon(
                    onPressed: () => _goToSchedules(facilityId, facilityName),
                    icon: const Icon(Icons.schedule, size: 16),
                    label: const Text('Schedules'),
                    style: OutlinedButton.styleFrom(
                        visualDensity: VisualDensity.compact),
                  ),
                  const SizedBox(width: 8),
                  FilledButton.icon(
                    onPressed: () => _goToCreate(facilityId),
                    icon: const Icon(Icons.add, size: 16),
                    label: const Text('New Reminder'),
                    style: FilledButton.styleFrom(
                        visualDensity: VisualDensity.compact),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            // ── Stats ────────────────────────────────────────────────────
            _buildStats(facilityId),
            const SizedBox(height: 12),
            // ── Filters ──────────────────────────────────────────────────
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
                        contentPadding:
                            const EdgeInsets.symmetric(vertical: 10),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8),
                        ),
                      ),
                      onChanged: (v) => setState(() => _searchQuery = v),
                    ),
                  ),
                  const SizedBox(width: 10),
                  DropdownButtonHideUnderline(
                    child: DropdownButton<ReminderType?>(
                      value: _typeFilter,
                      hint: const Text('All Types'),
                      isDense: true,
                      borderRadius: BorderRadius.circular(8),
                      items: [
                        const DropdownMenuItem(
                            value: null, child: Text('All Types')),
                        ...ReminderType.values.map((t) => DropdownMenuItem(
                              value: t,
                              child: Text(t.displayName),
                            )),
                      ],
                      onChanged: (v) => setState(() => _typeFilter = v),
                    ),
                  ),
                  const SizedBox(width: 10),
                  DropdownButtonHideUnderline(
                    child: DropdownButton<ReminderStatus?>(
                      value: _statusFilter,
                      hint: const Text('All Status'),
                      isDense: true,
                      borderRadius: BorderRadius.circular(8),
                      items: [
                        const DropdownMenuItem(
                            value: null, child: Text('All Status')),
                        ...ReminderStatus.values.map((s) => DropdownMenuItem(
                              value: s,
                              child: Text(s.displayName),
                            )),
                      ],
                      onChanged: (v) => setState(() => _statusFilter = v),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            Divider(height: 1, color: colorScheme.outlineVariant),
            // ── List ─────────────────────────────────────────────────────
            Expanded(child: _buildList(facilityId)),
          ],
        );
      },
    );
  }

  Widget _buildStats(String facilityId) {
    return Consumer(
      builder: (context, ref, _) {
        return ref.watch(reminderStatsProvider(facilityId)).when(
              data: (stats) => Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Row(
                  children: [
                    _statChip('Total', stats['total'] ?? 0, null),
                    const SizedBox(width: 8),
                    _statChip('Pending', stats['pending'] ?? 0, AppTheme.warning),
                    const SizedBox(width: 8),
                    _statChip('Sent', stats['sent'] ?? 0, AppTheme.success),
                    const SizedBox(width: 8),
                    _statChip('Past send date', stats['overdue'] ?? 0, AppTheme.error),
                  ],
                ),
              ),
              loading: () => const SizedBox(
                  height: 40,
                  child: Center(child: LinearProgressIndicator())),
              error: (_, __) => const SizedBox.shrink(),
            );
      },
    );
  }

  Widget _statChip(String label, int count, Color? color) {
    final colorScheme = Theme.of(context).colorScheme;
    final c = color ?? colorScheme.primary;
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 12),
        decoration: BoxDecoration(
          color: c.withOpacity(0.08),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: c.withOpacity(0.25)),
        ),
        child: Column(
          children: [
            Text(
              '$count',
              style: TextStyle(
                  fontSize: 20, fontWeight: FontWeight.w700, color: c),
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

  Widget _buildList(String facilityId) {
    return Consumer(
      builder: (context, ref, _) {
        return ref.watch(reminderListProvider(facilityId)).when(
              data: (reminders) {
                final filtered = reminders.where((r) {
                  if (_typeFilter != null && r.type != _typeFilter) return false;
                  if (_statusFilter != null && r.status != _statusFilter) {
                    return false;
                  }
                  if (_searchQuery.isNotEmpty) {
                    final q = _searchQuery.toLowerCase();
                    if (!r.title.toLowerCase().contains(q) &&
                        !r.message.toLowerCase().contains(q)) {
                      return false;
                    }
                  }
                  return true;
                }).toList();

                if (filtered.isEmpty) {
                  return Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.notifications_none,
                            size: 56,
                            color: Theme.of(context)
                                .colorScheme
                                .outlineVariant),
                        const SizedBox(height: 12),
                        Text('No reminders found',
                            style:
                                Theme.of(context).textTheme.titleMedium),
                        const SizedBox(height: 6),
                        Text(
                          reminders.isEmpty
                              ? 'Create your first reminder using the button above.'
                              : 'Try adjusting your filters.',
                          style: Theme.of(context)
                              .textTheme
                              .bodySmall
                              ?.copyWith(
                                color: Theme.of(context)
                                    .colorScheme
                                    .onSurfaceVariant,
                              ),
                          textAlign: TextAlign.center,
                        ),
                        if (reminders.isEmpty) ...[
                          const SizedBox(height: 16),
                          FilledButton.icon(
                            onPressed: () => _goToCreate(facilityId),
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
                  itemBuilder: (context, i) =>
                      _buildCard(filtered[i], facilityId),
                );
              },
              loading: () =>
                  const Center(child: CircularProgressIndicator()),
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
                      onPressed: () =>
                          ref.invalidate(reminderListProvider(facilityId)),
                      child: const Text('Retry'),
                    ),
                  ],
                ),
              ),
            );
      },
    );
  }

  Widget _buildCard(ReminderModel reminder, String facilityId) {
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
        onTap: () => _goToDetail(reminder, facilityId),
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
                      style:
                          Theme.of(context).textTheme.bodyMedium?.copyWith(
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
                        _chip(reminder.type.displayName, colorScheme.primary),
                        _chip(reminder.statusDisplayName, statusColor),
                        _chip(
                          '${reminder.scheduledFor.month}/${reminder.scheduledFor.day}/${reminder.scheduledFor.year}',
                          colorScheme.onSurfaceVariant,
                        ),
                        if (reminder.isOverdue)
                          _chip(
                            reminder.daysOverdue == 0
                                ? 'Due today'
                                : '${reminder.daysOverdue}d past send date',
                            AppTheme.error,
                          ),
                      ],
                    ),
                  ],
                ),
              ),
              if (reminder.status == ReminderStatus.pending)
                IconButton(
                  icon: const Icon(Icons.send, size: 18),
                  tooltip: 'Send now',
                  onPressed: () => _sendReminder(reminder, facilityId),
                  color: colorScheme.primary,
                  visualDensity: VisualDensity.compact,
                ),
              Icon(Icons.chevron_right,
                  size: 18, color: colorScheme.onSurfaceVariant),
            ],
          ),
        ),
      ),
    );
  }

  Widget _chip(String label, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withOpacity(0.1),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        label,
        style:
            TextStyle(fontSize: 10, color: color, fontWeight: FontWeight.w500),
      ),
    );
  }

  Widget _buildNoFacilities() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.business,
              size: 64,
              color: Theme.of(context).colorScheme.outlineVariant),
          const SizedBox(height: 16),
          Text('No Facilities Found',
              style: Theme.of(context).textTheme.headlineSmall),
          const SizedBox(height: 8),
          Text(
            'You must create a storage facility before managing reminders.',
            style: Theme.of(context).textTheme.bodyMedium,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 24),
          FilledButton(
            onPressed: () => context.go('/facilities/new'),
            child: const Text('Create Facility'),
          ),
        ],
      ),
    );
  }

  void _goToCreate(String facilityId) {
    context
        .push('${AppRoute.reminderCreate}?facilityId=$facilityId')
        .then((_) {
      if (mounted) {
        ref.invalidate(reminderListProvider(facilityId));
        ref.invalidate(reminderStatsProvider(facilityId));
      }
    });
  }

  void _goToDetail(ReminderModel reminder, String facilityId) {
    context.push(AppRoute.reminderDetail, extra: reminder).then((_) {
      if (mounted) {
        ref.invalidate(reminderListProvider(facilityId));
        ref.invalidate(reminderStatsProvider(facilityId));
      }
    });
  }

  void _goToSchedules(String facilityId, String facilityName) {
    context.push(
      '${AppRoute.reminderSchedule}?facilityId=$facilityId&facilityName=${Uri.encodeComponent(facilityName)}',
    );
  }

  void _sendReminder(ReminderModel reminder, String facilityId) {
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
}
