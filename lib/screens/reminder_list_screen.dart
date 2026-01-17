import 'package:flutter/foundation.dart' show debugPrint, kDebugMode;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:sfcapp/models/facility_model.dart';
import 'package:sfcapp/models/reminder_model.dart';
import 'package:sfcapp/providers/auth_provider.dart';
import 'package:sfcapp/providers/facility_provider.dart';
import 'package:sfcapp/providers/reminder_provider.dart';
import 'package:sfcapp/router/app_route.dart';
import 'package:sfcapp/screens/facility_creation_wizard.dart';
import 'package:sfcapp/screens/facility_map_editor_screen.dart';
import 'package:sfcapp/screens/reminder_creation_screen.dart';
import 'package:sfcapp/screens/reminder_detail_screen.dart';
import 'package:sfcapp/screens/reminder_schedule_screen.dart';
import 'package:sfcapp/services/facility_creator_account_service.dart';
import 'package:sfcapp/services/modern_navigation_service.dart';
import 'package:sfcapp/theme/app_theme.dart';
import 'package:sfcapp/widgets/modern_page_wrapper.dart';

class ReminderListScreen extends ConsumerStatefulWidget {
  const ReminderListScreen({super.key});

  @override
  ConsumerState<ReminderListScreen> createState() => _ReminderListScreenState();
}

class _ReminderListScreenState extends ConsumerState<ReminderListScreen> {
  String _selectedFacilityId = '';
  String _selectedFacilityName = '';
  String _searchQuery = '';
  ReminderType? _typeFilter;
  ReminderStatus? _statusFilter;

  @override
  void initState() {
    super.initState();
    _loadUserFacilities();
  }

  Future<void> _loadUserFacilities() async {
    try {
      final authState = ref.read(authStateProvider);
      if (authState.hasValue && authState.value != null) {
        final user = authState.value!;
        
        // CRITICAL: Ensure account exists BEFORE trying to load facilities
        try {
          await FacilityCreatorAccountService.getOrCreateAccountForCurrentUser();
          if (kDebugMode) {
            debugPrint('✅ Account verified/created for user: ${user.uid}');
          }
        } catch (accountError) {
          if (mounted) {
            debugPrint('❌ Could not ensure account exists: $accountError');
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text('Account setup error: $accountError. Please try again.'),
                backgroundColor: AppTheme.warning,
                duration: const Duration(seconds: 5),
                action: SnackBarAction(
                  label: 'Retry',
                  onPressed: () => _loadUserFacilities(),
                ),
              ),
            );
            return;
          }
        }
        
        // Small delay to ensure account is fully created
        await Future.delayed(const Duration(milliseconds: 500));
        
        final facilitiesAsync = await ref.read(userFacilitiesProvider(user.uid).future);
        final facilities = facilitiesAsync as List<FacilityModel>? ?? <FacilityModel>[];
        if (facilities.isNotEmpty) {
          setState(() {
            _selectedFacilityId = facilities.first.id;
            _selectedFacilityName = facilities.first.name;
          });
        }
      }
    } catch (e) {
      if (mounted) {
        debugPrint('❌ Error loading facilities in reminder screen: $e');
        final errorMessage = e.toString();
        final isPermissionError = errorMessage.contains('permission-denied') || 
                                  errorMessage.contains('Missing or insufficient permissions');
        
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              isPermissionError
                  ? 'Permission error: Your account may need setup. Please check your account status.'
                  : 'Error loading facilities: $errorMessage',
            ),
            backgroundColor: AppTheme.error,
            duration: const Duration(seconds: 6),
            action: SnackBarAction(
              label: 'Retry',
              onPressed: () => _loadUserFacilities(),
            ),
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return ModernPageWrapper(
      currentRoute: '/reminders',
      title: 'Reminders',
      onNavigate: (route) {
        ModernNavigationService.navigateToRoute(context, route);
      },
      actions: [
        IconButton(
          icon: const Icon(Icons.add),
          onPressed: _selectedFacilityId.isNotEmpty
              ? () => _navigateToCreateReminder()
              : null,
          tooltip: 'Add Reminder',
        ),
        IconButton(
          icon: const Icon(Icons.schedule),
          tooltip: 'Automation schedules',
          onPressed: _selectedFacilityId.isNotEmpty
              ? () => _navigateToSchedules()
              : null,
        ),
        IconButton(
          icon: const Icon(Icons.refresh),
          onPressed: _selectedFacilityId.isNotEmpty
              ? () => _processReminders()
              : null,
          tooltip: 'Process Reminders',
        ),
      ],
      child: _selectedFacilityId.isEmpty
          ? _buildNoFacilitiesMessage()
          : Column(
              children: [
                _buildFilters(),
                _buildStats(),
                Expanded(
                  child: _buildRemindersList(),
                ),
              ],
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
            'You must create a storage facility before managing reminders.',
            style: Theme.of(context).textTheme.bodyMedium,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 24),
          ElevatedButton(
            onPressed: () => context.go('/facilities/new'),
            child: const Text('Create Facility'),
          ),
        ],
      ),
    );
  }

  Widget _buildFilters() {
    return Container(
      padding: const EdgeInsets.all(16),
      child: Column(
        children: [
          // Facility selector
          Consumer(
            builder: (context, ref, child) {
              return ref.watch(authStateProvider).when(
                data: (user) {
                  if (user == null) return const SizedBox.shrink();
                  
                  return ref.watch(userFacilitiesProvider(user.uid)).when(
                    data: (facilities) {
                      if (facilities.isEmpty) return const SizedBox.shrink();
                      
                      return Row(
                        children: [
                          Expanded(
                            child: DropdownButtonFormField<String>(
                              value: _selectedFacilityId,
                              decoration: const InputDecoration(
                                labelText: 'Facility',
                                border: OutlineInputBorder(),
                              ),
                              items: facilities.map((facility) {
                                return DropdownMenuItem(
                                  value: facility.id,
                                  child: Text(facility.name),
                                );
                              }).toList(),
                              onChanged: (value) {
                                setState(() {
                                  _selectedFacilityId = value ?? '';
                                  final match = facilities.firstWhere(
                                    (facility) => facility.id == value,
                                    orElse: () => facilities.first,
                                  );
                                  _selectedFacilityName = match.name;
                                });
                              },
                            ),
                          ),
                          if (_selectedFacilityId.isNotEmpty) ...[
                            const SizedBox(width: 8),
                            IconButton(
                              onPressed: () => context.push('/units/map?facilityId=$_selectedFacilityId'),
                              icon: const Icon(Icons.map),
                              tooltip: 'View Map',
                              color: AppTheme.primaryBlue,
                            ),
                          ],
                        ],
                      );
                    },
                    loading: () => const _InlineLoader(message: 'Loading facilities...'),
                    error: (_, __) => const Text('Error loading facilities'),
                  );
                },
                loading: () => const _InlineLoader(message: 'Loading account...'),
                error: (_, __) => const Text('Error loading user'),
              );
            },
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: TextField(
                  decoration: const InputDecoration(
                    labelText: 'Search reminders',
                    prefixIcon: Icon(Icons.search),
                    border: OutlineInputBorder(),
                  ),
                  onChanged: (value) {
                    setState(() {
                      _searchQuery = value;
                    });
                  },
                ),
              ),
              const SizedBox(width: 16),
              DropdownButton<ReminderType?>(
                value: _typeFilter,
                hint: const Text('Type'),
                items: [
                  const DropdownMenuItem(
                    value: null,
                    child: Text('All Types'),
                  ),
                  ...ReminderType.values.map((type) {
                    return DropdownMenuItem(
                      value: type,
                      child: Text(type.displayName),
                    );
                  }),
                ],
                onChanged: (value) {
                  setState(() {
                    _typeFilter = value;
                  });
                },
              ),
              const SizedBox(width: 8),
              DropdownButton<ReminderStatus?>(
                value: _statusFilter,
                hint: const Text('Status'),
                items: [
                  const DropdownMenuItem(
                    value: null,
                    child: Text('All Status'),
                  ),
                  ...ReminderStatus.values.map((status) {
                    return DropdownMenuItem(
                      value: status,
                      child: Text(status.displayName),
                    );
                  }),
                ],
                onChanged: (value) {
                  setState(() {
                    _statusFilter = value;
                  });
                },
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildStats() {
    return Consumer(
      builder: (context, ref, child) {
        return ref.watch(reminderListProvider(_selectedFacilityId)).when(
          data: (reminders) {
            final stats = ref.watch(reminderStatsProvider(_selectedFacilityId));
            
            return stats.when(
              data: (statsData) => Container(
                padding: const EdgeInsets.all(16),
                child: Row(
                  children: [
                    Expanded(
                      child: _buildStatCard(
                        'Total',
                        statsData['total']?.toString() ?? '0',
                        AppTheme.primaryBlue,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: _buildStatCard(
                        'Pending',
                        statsData['pending']?.toString() ?? '0',
                        AppTheme.warning,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: _buildStatCard(
                        'Sent',
                        statsData['sent']?.toString() ?? '0',
                        AppTheme.success,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: _buildStatCard(
                        'Overdue',
                        statsData['overdue']?.toString() ?? '0',
                        AppTheme.error,
                      ),
                    ),
                  ],
                ),
              ),
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (_, __) => const Center(child: Text('Error loading stats')),
            );
          },
          loading: () => const SizedBox.shrink(),
          error: (_, __) => const SizedBox.shrink(),
        );
      },
    );
  }

  Widget _buildStatCard(String title, String count, Color color) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          children: [
            Text(
              title,
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 4),
            Text(
              count,
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                color: color,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildRemindersList() {
    return Consumer(
      builder: (context, ref, child) {
        return ref.watch(reminderListProvider(_selectedFacilityId)).when(
          data: (reminders) {
            // Apply filters
            final filteredReminders = reminders.where((reminder) {
              // Type filter
              if (_typeFilter != null && reminder.type != _typeFilter) {
                return false;
              }
              
              // Status filter
              if (_statusFilter != null && reminder.status != _statusFilter) {
                return false;
              }
              
              // Search filter
              if (_searchQuery.isNotEmpty) {
                final query = _searchQuery.toLowerCase();
                final title = reminder.title.toLowerCase();
                final message = reminder.message.toLowerCase();
                final tenantId = reminder.tenantId.toLowerCase();
                
                if (!title.contains(query) && 
                    !message.contains(query) && 
                    !tenantId.contains(query)) {
                  return false;
                }
              }
              
              return true;
            }).toList();
            
            if (filteredReminders.isEmpty) {
              return Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 120),
                child: Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        Icons.notifications,
                        size: 64,
                        color: AppTheme.textTertiary,
                      ),
                      const SizedBox(height: 16),
                      Text(
                        'No reminders found',
                        style: Theme.of(context).textTheme.headlineSmall,
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'Create your first reminder or adjust your filters.',
                        style: Theme.of(context).textTheme.bodyMedium,
                        textAlign: TextAlign.center,
                      ),
                    ],
                  ),
                ),
              );
            }
            
            return ListView.builder(
              padding: const EdgeInsets.fromLTRB(0, 0, 0, 120),
              itemCount: filteredReminders.length,
              itemBuilder: (context, index) {
                final reminder = filteredReminders[index];
                return _buildReminderCard(reminder);
              },
            );
          },
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (error, stackTrace) => Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  Icons.error,
                  size: 64,
                  color: AppTheme.error,
                ),
                const SizedBox(height: 16),
                Text(
                  'Error loading reminders',
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
                const SizedBox(height: 8),
                Text(
                  error.toString(),
                  style: Theme.of(context).textTheme.bodyMedium,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 16),
                ElevatedButton(
                  onPressed: () {
                    ref.invalidate(reminderListProvider(_selectedFacilityId));
                  },
                  child: const Text('Retry'),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildReminderCard(ReminderModel reminder) {
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: _getStatusColor(reminder.status),
          child: Icon(
            _getStatusIcon(reminder.status),
            color: AppTheme.textOnDark,
          ),
        ),
        title: Text(
          reminder.title,
          style: Theme.of(context).textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.bold,
          ),
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(reminder.message),
            const SizedBox(height: 4),
            Row(
              children: [
                Text('Type: ${reminder.type.displayName}'),
                const SizedBox(width: 16),
                Text('Status: ${reminder.statusDisplayName}'),
              ],
            ),
            Text('Scheduled: ${_formatDate(reminder.scheduledFor)}'),
            if (reminder.isOverdue)
              Text(
                'Overdue by ${reminder.daysUntilDue} days',
                style: TextStyle(color: AppTheme.error),
              ),
            Text('Channels: ${reminder.channelsDisplayName}'),
          ],
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (reminder.status == ReminderStatus.pending)
              IconButton(
                icon: const Icon(Icons.send),
                onPressed: () => _sendReminder(reminder),
              ),
            IconButton(
              icon: const Icon(Icons.arrow_forward_ios),
              onPressed: () => _navigateToReminderDetail(reminder),
            ),
          ],
        ),
        onTap: () => _navigateToReminderDetail(reminder),
      ),
    );
  }

  Color _getStatusColor(ReminderStatus status) {
    switch (status) {
      case ReminderStatus.pending:
        return AppTheme.warning;
      case ReminderStatus.sent:
        return AppTheme.success;
      case ReminderStatus.failed:
        return AppTheme.error;
      case ReminderStatus.cancelled:
        return AppTheme.textTertiary;
    }
  }

  IconData _getStatusIcon(ReminderStatus status) {
    switch (status) {
      case ReminderStatus.pending:
        return Icons.pending;
      case ReminderStatus.sent:
        return Icons.check;
      case ReminderStatus.failed:
        return Icons.error;
      case ReminderStatus.cancelled:
        return Icons.cancel;
    }
  }

  String _formatDate(DateTime date) {
    return '${date.month}/${date.day}/${date.year}';
  }

  void _navigateToCreateReminder() {
    context.push(
      '${AppRoute.reminderCreate}?facilityId=$_selectedFacilityId',
    ).then((_) {
      // Refresh providers when returning from reminder creation
      ref.invalidate(reminderListProvider(_selectedFacilityId));
      ref.invalidate(reminderStatsProvider(_selectedFacilityId));
    });
  }

  void _navigateToReminderDetail(ReminderModel reminder) {
    context.push(
      AppRoute.reminderDetail,
      extra: reminder,
    ).then((_) {
      // Refresh providers when returning from reminder detail
      ref.invalidate(reminderListProvider(_selectedFacilityId));
      ref.invalidate(reminderStatsProvider(_selectedFacilityId));
    });
  }

  void _sendReminder(ReminderModel reminder) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Send Reminder'),
        content: Text('Send reminder "${reminder.title}"?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () async {
              Navigator.of(context).pop();
              await ref.read(reminderOperationsProvider.notifier).sendReminder(
                facilityId: reminder.facilityId,
                reminderId: reminder.id,
                tenantEmail: reminder.tenantEmail ?? '',
                tenantPhone: reminder.tenantPhone ?? '',
                message: reminder.message,
                channels: reminder.channels,
              );
              // Refresh providers after sending reminder
              ref.invalidate(reminderListProvider(_selectedFacilityId));
              ref.invalidate(reminderStatsProvider(_selectedFacilityId));
            },
            child: const Text('Send'),
          ),
        ],
      ),
    );
  }

  void _navigateToSchedules() {
    context.push(
      '${AppRoute.reminderSchedule}?facilityId=$_selectedFacilityId&facilityName=${Uri.encodeComponent(_selectedFacilityName.isEmpty ? 'Facility' : _selectedFacilityName)}',
    );
  }

  void _processReminders() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Run automated schedules'),
        content: const Text(
          'Run all active reminder schedules now? This will generate reminders and '
          'send SMS/email messages according to your automation rules.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () async {
              Navigator.of(context).pop();
              try {
                final result = await ref
                    .read(reminderOperationsProvider.notifier)
                    .runAutomation(_selectedFacilityId);

                if (!mounted) return;
                ref.invalidate(reminderListProvider(_selectedFacilityId));
                ref.invalidate(reminderStatsProvider(_selectedFacilityId));

                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text(
                      'Processed ${result.schedulesProcessed} schedule(s). '
                      '${result.remindersCreated} reminder(s) created, '
                      '${result.remindersSent} sent, '
                      '${result.digestQueued} queued for digest.',
                    ),
                  ),
                );
              } catch (e) {
                if (!mounted) return;
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('Automation failed: $e')),
                );
              }
            },
            child: const Text('Run now'),
          ),
        ],
      ),
    );
  }
}

class _InlineLoader extends StatelessWidget {
  final String message;
  const _InlineLoader({required this.message});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8.0),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          const SizedBox(width: 12),
          Text(message),
        ],
      ),
    );
  }
}
