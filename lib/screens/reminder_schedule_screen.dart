import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sfcapp/models/permission_model.dart';
import 'package:sfcapp/models/reminder_model.dart';
import 'package:sfcapp/models/reminder_schedule_model.dart';
import 'package:sfcapp/providers/reminder_schedule_provider.dart';
import 'package:sfcapp/services/permission_service.dart';
import 'package:sfcapp/theme/app_theme.dart';

class ReminderScheduleScreen extends ConsumerStatefulWidget {
  final String facilityId;
  final String facilityName;

  const ReminderScheduleScreen({
    super.key,
    required this.facilityId,
    required this.facilityName,
  });

  @override
  ConsumerState<ReminderScheduleScreen> createState() => _ReminderScheduleScreenState();
}

class _ReminderScheduleScreenState extends ConsumerState<ReminderScheduleScreen> {
  bool _loadingPermission = true;
  bool _canManageSchedules = false;
  String? _permissionReason;

  @override
  void initState() {
    super.initState();
    _checkPermissions();
  }

  Future<void> _checkPermissions() async {
    setState(() {
      _loadingPermission = true;
    });
    final check = await PermissionService.hasPermission(
      permission: PermissionType.editReminder,
      facilityId: widget.facilityId,
    );
    if (!mounted) return;
    setState(() {
      _loadingPermission = false;
      _canManageSchedules = check.hasPermission;
      _permissionReason = check.reason;
    });
  }

  @override
  Widget build(BuildContext context) {
    final schedulesAsync = ref.watch(reminderSchedulesProvider(widget.facilityId));
    final theme = Theme.of(context);
    final cs = theme.colorScheme;

    return Scaffold(
      appBar: AppBar(
        backgroundColor: cs.surface,
        foregroundColor: cs.onSurface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 1,
        title: Text(
          'Reminder Schedules • ${widget.facilityName}',
          style: theme.textTheme.titleLarge
              ?.copyWith(fontWeight: FontWeight.w600, letterSpacing: -0.2),
        ),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(1),
          child: Divider(height: 1, thickness: 1, color: cs.outlineVariant),
        ),
      ),
      floatingActionButton: _canManageSchedules
          ? FloatingActionButton.extended(
              onPressed: () => _showScheduleEditor(),
              icon: const Icon(Icons.add),
              label: const Text('Add Schedule'),
            )
          : null,
      body: _loadingPermission
          ? const Center(child: CircularProgressIndicator())
          : schedulesAsync.when(
        data: (schedules) {
          if (schedules.isEmpty) {
            return _buildEmptyState();
          }
          return Column(
            children: [
              if (!_canManageSchedules)
                MaterialBanner(
                  content: Text(
                    _permissionReason ?? 'You have read-only access to automation schedules for this facility.',
                  ),
                  leading: const Icon(Icons.lock_outline),
                  backgroundColor: AppTheme.warning.withOpacity(0.1),
                  actions: const [SizedBox.shrink()],
                ),
              Expanded(
                child: ListView.builder(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 100),
                  itemCount: schedules.length,
                  itemBuilder: (context, index) {
                    final schedule = schedules[index];
                    return _buildScheduleCard(schedule);
                  },
                ),
              ),
            ],
          );
        },
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, stackTrace) => Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.error_outline, size: 48, color: AppTheme.error),
                const SizedBox(height: 16),
                Text(
                  'Unable to load schedules',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 8),
                Text(
                  error.toString(),
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.schedule_send_outlined,
              size: 64,
              color: AppTheme.primaryBlue.withOpacity(0.5),
            ),
            const SizedBox(height: 16),
            Text(
              'No automated schedules yet',
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            const SizedBox(height: 8),
            Text(
              'Create a schedule to automatically send SMS and email reminders for upcoming rent due dates, overdue accounts, or expiring contracts.',
              style: Theme.of(context).textTheme.bodyMedium,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            ElevatedButton.icon(
              onPressed: _canManageSchedules ? () => _showScheduleEditor() : null,
              icon: const Icon(Icons.add),
              label: const Text('Create Schedule'),
            ),
            if (!_canManageSchedules) ...[
              const SizedBox(height: 12),
              Text(
                _permissionReason ?? 'You do not have permission to create automation schedules.',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(color: AppTheme.textSecondary),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildScheduleCard(ReminderScheduleModel schedule) {
    final subtitle = <String>[
      _typeDescription(schedule),
      'Run ${_timeDisplay(schedule.sendTime)} • Offset ${schedule.offsetDays} day${schedule.offsetDays == 1 ? '' : 's'}',
      'Channels: ${schedule.channels.map((e) => e.displayName).join(', ')}',
    ];

    if (schedule.lastRunDate != null) {
      subtitle.add('Last run: ${schedule.lastRunDate}');
    }

    return Card(
      margin: const EdgeInsets.symmetric(vertical: 6),
      child: ListTile(
        leading: Switch(
          value: schedule.isActive,
          onChanged: _canManageSchedules ? (value) => _toggleSchedule(schedule, value) : null,
        ),
        title: Text(
          schedule.name,
          style: Theme.of(context).textTheme.titleMedium,
        ),
        subtitle: Text(subtitle.join('\n')),
        isThreeLine: true,
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              icon: const Icon(Icons.edit),
              tooltip: 'Edit schedule',
              onPressed: _canManageSchedules ? () => _showScheduleEditor(schedule: schedule) : null,
            ),
            IconButton(
              icon: const Icon(Icons.delete_outline),
              tooltip: 'Delete schedule',
              onPressed: _canManageSchedules ? () => _confirmDelete(schedule) : null,
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _toggleSchedule(ReminderScheduleModel schedule, bool isActive) async {
    if (!_canManageSchedules) return;
    try {
      await ref
          .read(reminderScheduleOperationsProvider.notifier)
          .toggleSchedule(
            facilityId: widget.facilityId,
            scheduleId: schedule.id,
            isActive: isActive,
          );
      ref.invalidate(reminderSchedulesProvider(widget.facilityId));
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            '${schedule.name} ${isActive ? 'enabled' : 'paused'}',
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Unable to update schedule: $e')),
      );
    }
  }

  Future<void> _confirmDelete(ReminderScheduleModel schedule) async {
    if (!_canManageSchedules) return;
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete schedule?'),
        content: Text('Are you sure you want to delete "${schedule.name}"?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (confirm != true) return;

    try {
      await ref
          .read(reminderScheduleOperationsProvider.notifier)
          .deleteSchedule(facilityId: widget.facilityId, scheduleId: schedule.id);
      ref.invalidate(reminderSchedulesProvider(widget.facilityId));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Unable to delete schedule: $e')),
      );
    }
  }

  Future<void> _showScheduleEditor({ReminderScheduleModel? schedule}) async {
    if (!_canManageSchedules) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(_permissionReason ?? 'You do not have permission to manage automation schedules.'),
        ),
      );
      return;
    }
    final isEditing = schedule != null;

    ReminderType selectedType = schedule?.type ?? ReminderType.rentDue;
    List<ReminderChannel> selectedChannels =
        schedule?.channels ?? [ReminderChannel.email];
    ReminderSendMode selectedSendMode =
        schedule?.sendMode ?? ReminderSendMode.immediate;
    int offsetDays = schedule?.offsetDays ?? 3;
    TimeOfDay sendTime = _parseTime(schedule?.sendTime ?? '09:00');
    bool autoSend = schedule?.autoSend ?? true;
    String name = schedule?.name ??
        _defaultScheduleName(selectedType);
    String titleTemplate = schedule?.titleTemplate ??
        _defaultTitleTemplate(selectedType);
    String messageTemplate = schedule?.messageTemplate ??
        _defaultMessageTemplate(selectedType);

    final nameController = TextEditingController(text: name);
    final titleController = TextEditingController(text: titleTemplate);
    final messageController = TextEditingController(text: messageTemplate);
    final offsetController = TextEditingController(text: offsetDays.toString());

    final result = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (context) => Padding(
        padding: EdgeInsets.only(
          left: 16,
          right: 16,
          bottom: MediaQuery.of(context).viewInsets.bottom + 24,
          top: 24,
        ),
        child: StatefulBuilder(
          builder: (context, setState) {
            return SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    isEditing ? 'Edit Schedule' : 'New Schedule',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: nameController,
                    decoration: const InputDecoration(
                      labelText: 'Schedule name',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 16),
                  DropdownButtonFormField<ReminderType>(
                    value: selectedType,
                    decoration: const InputDecoration(
                      labelText: 'Reminder type',
                      border: OutlineInputBorder(),
                    ),
                    onChanged: (value) {
                      if (value == null) return;
                      setState(() {
                        selectedType = value;
                        nameController.text = _defaultScheduleName(value);
                        titleController.text = _defaultTitleTemplate(value);
                        messageController.text = _defaultMessageTemplate(value);
                      });
                    },
                    items: _supportedTypes
                        .map(
                          (type) => DropdownMenuItem(
                            value: type,
                            child: Text(type.displayName),
                          ),
                        )
                        .toList(),
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: offsetController,
                    keyboardType: TextInputType.number,
                    decoration: InputDecoration(
                      labelText: _offsetLabel(selectedType),
                      border: const OutlineInputBorder(),
                      helperText: _offsetHelper(selectedType),
                    ),
                    onChanged: (value) {
                      final parsed = int.tryParse(value);
                      if (parsed != null) {
                        offsetDays = parsed;
                      }
                    },
                  ),
                  const SizedBox(height: 16),
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Send time'),
                    subtitle: Text(_timeDisplay(_timeString(sendTime))),
                    trailing: IconButton(
                      icon: const Icon(Icons.schedule_outlined),
                      onPressed: () async {
                        final time = await showTimePicker(
                          context: context,
                          initialTime: sendTime,
                        );
                        if (time != null) {
                          setState(() {
                            sendTime = time;
                          });
                        }
                      },
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Delivery channels',
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    children: ReminderChannel.values.map((channel) {
                      final enabled = channel != ReminderChannel.push &&
                          channel != ReminderChannel.inApp;
                      final selected = selectedChannels.contains(channel);
                      return FilterChip(
                        label: Text(channel.displayName),
                        selected: selected,
                        onSelected: enabled
                            ? (value) {
                                setState(() {
                                  if (value) {
                                    selectedChannels.add(channel);
                                  } else {
                                    selectedChannels.remove(channel);
                                  }
                                });
                              }
                            : null,
                      );
                    }).toList(),
                  ),
                  const SizedBox(height: 16),
                  DropdownButtonFormField<ReminderSendMode>(
                    value: selectedSendMode,
                    decoration: const InputDecoration(
                      labelText: 'Send mode',
                      border: OutlineInputBorder(),
                    ),
                    onChanged: (value) {
                      if (value == null) return;
                      setState(() => selectedSendMode = value);
                    },
                    items: ReminderSendMode.values
                        .map(
                          (mode) => DropdownMenuItem(
                            value: mode,
                            child: Text(_modeLabel(mode)),
                          ),
                        )
                        .toList(),
                  ),
                  const SizedBox(height: 16),
                  SwitchListTile.adaptive(
                    value: autoSend,
                    onChanged: (value) => setState(() => autoSend = value),
                    title: const Text('Send automatically'),
                    subtitle: const Text(
                      'If disabled, reminders will be created as pending and can be reviewed manually.',
                    ),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: titleController,
                    decoration: const InputDecoration(
                      labelText: 'Email/SMS subject',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: messageController,
                    maxLines: 4,
                    decoration: const InputDecoration(
                      labelText: 'Message template',
                      border: OutlineInputBorder(),
                      helperText:
                          'Use placeholders like {{tenantName}}, {{dueDate}}, {{amount}}, {{facilityName}}.',
                    ),
                  ),
                  const SizedBox(height: 24),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      TextButton(
                        onPressed: () => Navigator.of(context).pop(false),
                        child: const Text('Cancel'),
                      ),
                      const SizedBox(width: 12),
                      ElevatedButton(
                        onPressed: () => Navigator.of(context).pop(true),
                        child: Text(isEditing ? 'Update' : 'Create'),
                      ),
                    ],
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );

    if (result != true) return;

    final notifier = ref.read(reminderScheduleOperationsProvider.notifier);
    try {
      if (isEditing) {
        await notifier.updateSchedule(
          facilityId: widget.facilityId,
          scheduleId: schedule!.id,
          name: nameController.text.trim(),
          type: selectedType,
          channels: selectedChannels,
          sendMode: selectedSendMode,
          offsetDays: int.tryParse(offsetController.text) ?? offsetDays,
          sendTime: _timeString(sendTime),
          autoSend: autoSend,
          titleTemplate: titleController.text.trim(),
          messageTemplate: messageController.text.trim(),
        );
      } else {
        await notifier.createSchedule(
          facilityId: widget.facilityId,
          name: nameController.text.trim(),
          type: selectedType,
          channels: selectedChannels,
          sendMode: selectedSendMode,
          offsetDays: int.tryParse(offsetController.text) ?? offsetDays,
          sendTime: _timeString(sendTime),
          autoSend: autoSend,
          isActive: true,
          titleTemplate: titleController.text.trim(),
          messageTemplate: messageController.text.trim(),
        );
      }
      ref.invalidate(reminderSchedulesProvider(widget.facilityId));
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            isEditing ? 'Schedule updated' : 'Schedule created',
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Unable to save schedule: $e')),
      );
    }
  }

  TimeOfDay _parseTime(String value) {
    final parts = value.split(':');
    if (parts.length != 2) return const TimeOfDay(hour: 9, minute: 0);
    final hour = int.tryParse(parts[0]) ?? 9;
    final minute = int.tryParse(parts[1]) ?? 0;
    return TimeOfDay(hour: hour.clamp(0, 23), minute: minute.clamp(0, 59));
  }

  String _timeString(TimeOfDay time) {
    final hour = time.hour.toString().padLeft(2, '0');
    final minute = time.minute.toString().padLeft(2, '0');
    return '$hour:$minute';
  }

  String _timeDisplay(String time) {
    final parts = time.split(':');
    if (parts.length != 2) return time;
    final hour = int.tryParse(parts[0]) ?? 0;
    final minute = int.tryParse(parts[1]) ?? 0;
    final period = hour >= 12 ? 'PM' : 'AM';
    final normalizedHour = hour % 12 == 0 ? 12 : hour % 12;
    return '$normalizedHour:${minute.toString().padLeft(2, '0')} $period';
  }

  String _typeDescription(ReminderScheduleModel schedule) {
    switch (schedule.type) {
      case ReminderType.rentDue:
        return 'Rent due reminders • ${schedule.offsetDays} day(s) before due date';
      case ReminderType.rentOverdue:
        return 'Rent overdue follow-up • ${schedule.offsetDays} day(s) after due date';
      case ReminderType.contractExpiring:
        return 'Contract renewal reminders • ${schedule.offsetDays} day(s) before expiry';
      default:
        return schedule.type.displayName;
    }
  }

  String _offsetLabel(ReminderType type) {
    switch (type) {
      case ReminderType.rentDue:
        return 'Days before due date';
      case ReminderType.rentOverdue:
        return 'Days after due date';
      case ReminderType.contractExpiring:
        return 'Days before contract expiry';
      default:
        return 'Day offset';
    }
  }

  String _offsetHelper(ReminderType type) {
    switch (type) {
      case ReminderType.rentDue:
        return 'Send this many days before the rent payment due date.';
      case ReminderType.rentOverdue:
        return 'Send this many days after the rent payment becomes overdue.';
      case ReminderType.contractExpiring:
        return 'Send this many days before the contract expiration date.';
      default:
        return 'Positive values send before the event, negative values after.';
    }
  }

  static const List<ReminderType> _supportedTypes = [
    ReminderType.rentDue,
    ReminderType.rentOverdue,
    ReminderType.contractExpiring,
  ];

  String _defaultScheduleName(ReminderType type) {
    switch (type) {
      case ReminderType.rentDue:
        return 'Rent due notification';
      case ReminderType.rentOverdue:
        return 'Overdue rent follow-up';
      case ReminderType.contractExpiring:
        return 'Contract renewal reminder';
      default:
        return 'Reminder schedule';
    }
  }

  String _defaultTitleTemplate(ReminderType type) {
    switch (type) {
      case ReminderType.rentDue:
        return 'Rent payment due soon';
      case ReminderType.rentOverdue:
        return 'Rent payment overdue';
      case ReminderType.contractExpiring:
        return 'Storage contract expiring soon';
      default:
        return 'Reminder from {{facilityName}}';
    }
  }

  String _defaultMessageTemplate(ReminderType type) {
    switch (type) {
      case ReminderType.rentDue:
        return 'Hello {{tenantName}}, your rent payment of {{amount}} for unit {{unitNumber}} is due on {{dueDate}}. Please ensure payment is submitted to avoid late fees.';
      case ReminderType.rentOverdue:
        return 'Hello {{tenantName}}, our records show your rent payment of {{amount}} for unit {{unitNumber}} is {{daysOverdue}} day(s) overdue. Please contact us or pay promptly to avoid further action.';
      case ReminderType.contractExpiring:
        return 'Hello {{tenantName}}, your storage contract "{{contractTitle}}" is scheduled to expire on {{expiryDate}}. Please contact us to renew or discuss next steps.';
      default:
        return 'Hello {{tenantName}}, this is a reminder from {{facilityName}} regarding your account.';
    }
  }

  String _modeLabel(ReminderSendMode mode) {
    switch (mode) {
      case ReminderSendMode.immediate:
        return 'Send immediately';
      case ReminderSendMode.digest:
        return 'Queue for daily digest';
    }
  }
}

