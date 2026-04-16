import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../models/permission_model.dart';
import '../models/reminder_model.dart';
import '../providers/reminder_provider.dart';
import '../services/permission_service.dart';
import '../theme/app_theme.dart';

class ReminderDetailScreen extends ConsumerStatefulWidget {
  final ReminderModel reminder;

  const ReminderDetailScreen({
    super.key,
    required this.reminder,
  });

  @override
  ConsumerState<ReminderDetailScreen> createState() => _ReminderDetailScreenState();
}

class _ReminderDetailScreenState extends ConsumerState<ReminderDetailScreen> {
  bool _permissionsLoaded = false;
  bool _canDeleteReminder = false;
  bool _canMutateReminder = false;
  String _creatorLabel = '…';

  @override
  void initState() {
    super.initState();
    _loadCreatorAndPermissions();
  }

  Future<void> _loadCreatorAndPermissions() async {
    final facilityId = widget.reminder.facilityId;
    final deleteCheck = await PermissionService.hasPermission(
      permission: PermissionType.deleteReminder,
      facilityId: facilityId,
    );
    final editCheck = await PermissionService.hasPermission(
      permission: PermissionType.editReminder,
      facilityId: facilityId,
    );
    final createCheck = await PermissionService.hasPermission(
      permission: PermissionType.createReminder,
      facilityId: facilityId,
    );

    String creatorLabel = 'Not recorded';
    final uid = widget.reminder.createdBy.trim();
    if (uid.isNotEmpty) {
      try {
        final doc = await FirebaseFirestore.instance.collection('users').doc(uid).get();
        final data = doc.data();
        if (data != null) {
          final name = (data['displayName'] as String?)?.trim() ??
              (data['name'] as String?)?.trim() ??
              (data['email'] as String?)?.trim();
          if (name != null && name.isNotEmpty) {
            creatorLabel = name;
          } else {
            creatorLabel = _shortUid(uid);
          }
        } else {
          creatorLabel = _shortUid(uid);
        }
      } catch (_) {
        creatorLabel = _shortUid(uid);
      }
    }

    if (!mounted) return;
    setState(() {
      _permissionsLoaded = true;
      _canDeleteReminder = deleteCheck.hasPermission;
      _canMutateReminder = editCheck.hasPermission || createCheck.hasPermission;
      _creatorLabel = creatorLabel;
    });
  }

  String _shortUid(String uid) {
    if (uid.length <= 8) return uid;
    return 'User …${uid.substring(uid.length - 6)}';
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildStatusCard(),
          const SizedBox(height: 16),
          _buildReminderInfo(),
          const SizedBox(height: 16),
          _buildTimeline(),
          if (widget.reminder.metadata != null) ...[
            const SizedBox(height: 16),
            _buildMetadataSection(),
          ],
        ],
      ),
    );
  }

  Widget _buildStatusCard() {
    return Card(
      color: _getStatusColor(widget.reminder.status).withOpacity(0.1),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            CircleAvatar(
              backgroundColor: _getStatusColor(widget.reminder.status),
              child: Icon(
                _getStatusIcon(widget.reminder.status),
                color: AppTheme.textOnDark,
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    widget.reminder.statusDisplayName,
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                          color: _getStatusColor(widget.reminder.status),
                          fontWeight: FontWeight.bold,
                        ),
                  ),
                  Text(
                    widget.reminder.title,
                    style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                  ),
                  if (widget.reminder.isOverdue)
                    Text(
                      'Overdue by ${widget.reminder.daysUntilDue} days',
                      style: TextStyle(
                        color: AppTheme.error,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                ],
              ),
            ),
            _buildReminderActionsMenu(),
          ],
        ),
      ),
    );
  }

  Widget _buildReminderActionsMenu() {
    if (!_permissionsLoaded) {
      return const Padding(
        padding: EdgeInsets.only(left: 4),
        child: SizedBox(
          width: 40,
          height: 40,
          child: Center(
            child: SizedBox(
              width: 22,
              height: 22,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          ),
        ),
      );
    }

    final items = <PopupMenuEntry<String>>[];
    final r = widget.reminder;

    if (_canMutateReminder && r.status == ReminderStatus.pending) {
      items.add(
        const PopupMenuItem(
          value: 'send',
          child: Row(
            children: [
              Icon(Icons.send, size: 20),
              SizedBox(width: 12),
              Text('Send now'),
            ],
          ),
        ),
      );
      items.add(
        const PopupMenuItem(
          value: 'mark_sent',
          child: Row(
            children: [
              Icon(Icons.mark_email_read_outlined, size: 20),
              SizedBox(width: 12),
              Text('Mark as sent'),
            ],
          ),
        ),
      );
      items.add(
        const PopupMenuItem(
          value: 'cancel',
          child: Row(
            children: [
              Icon(Icons.cancel_outlined, size: 20),
              SizedBox(width: 12),
              Text('Cancel reminder'),
            ],
          ),
        ),
      );
    }

    if (_canMutateReminder &&
        r.status == ReminderStatus.sent &&
        r.readAt == null) {
      items.add(
        const PopupMenuItem(
          value: 'mark_read',
          child: Row(
            children: [
              Icon(Icons.done_all, size: 20),
              SizedBox(width: 12),
              Text('Mark as read'),
            ],
          ),
        ),
      );
    }

    if (_canDeleteReminder) {
      if (items.isNotEmpty) {
        items.add(const PopupMenuDivider());
      }
      items.add(
        const PopupMenuItem(
          value: 'delete',
          child: Row(
            children: [
              Icon(Icons.delete_outline, size: 20, color: AppTheme.error),
              SizedBox(width: 12),
              Text('Delete', style: TextStyle(color: AppTheme.error)),
            ],
          ),
        ),
      );
    }

    if (items.isEmpty) {
      return const SizedBox.shrink();
    }

    return PopupMenuButton<String>(
      icon: Icon(Icons.more_vert, color: Theme.of(context).colorScheme.onSurfaceVariant),
      onSelected: _handleMenuAction,
      itemBuilder: (context) => items,
    );
  }

  Widget _buildReminderInfo() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Reminder Information',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
            ),
            const SizedBox(height: 16),
            _buildInfoRow('Type', widget.reminder.type.displayName),
            _buildInfoRow('Status', widget.reminder.statusDisplayName),
            _buildInfoRow('Channels', widget.reminder.channelsDisplayName),
            _buildInfoRow('Scheduled For', _formatDateTime(widget.reminder.scheduledFor)),
            if (widget.reminder.sentAt != null)
              _buildInfoRow('Sent At', _formatDateTime(widget.reminder.sentAt!)),
            if (widget.reminder.readAt != null)
              _buildInfoRow('Read At', _formatDateTime(widget.reminder.readAt!)),
            _buildInfoRow('Created', _formatDateTime(widget.reminder.createdAt)),
            _buildInfoRow('Created by', _creatorLabel),
            _buildInfoRow('Updated', _formatDateTime(widget.reminder.updatedAt)),
            const SizedBox(height: 16),
            Text(
              'Message',
              style: Theme.of(context).textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
            ),
            const SizedBox(height: 8),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: AppTheme.backgroundLight,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: AppTheme.borderLight),
              ),
              child: Text(
                widget.reminder.message,
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildInfoRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 120,
            child: Text(
              '$label:',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w500,
                  ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTimeline() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Timeline',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
            ),
            const SizedBox(height: 16),
            _buildTimelineItem(
              'Reminder Created',
              _formatDateTime(widget.reminder.createdAt),
              Icons.add_circle,
              AppTheme.primaryBlue,
            ),
            if (widget.reminder.sentAt != null)
              _buildTimelineItem(
                'Reminder Sent',
                _formatDateTime(widget.reminder.sentAt!),
                Icons.send,
                AppTheme.success,
              ),
            if (widget.reminder.readAt != null)
              _buildTimelineItem(
                'Reminder Read',
                _formatDateTime(widget.reminder.readAt!),
                Icons.mark_email_read,
                AppTheme.warning,
              ),
            _buildTimelineItem(
              'Last Updated',
              _formatDateTime(widget.reminder.updatedAt),
              Icons.update,
              AppTheme.textTertiary,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTimelineItem(String title, String date, IconData icon, Color color) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          Icon(icon, color: color, size: 20),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w500,
                      ),
                ),
                Text(
                  date,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: AppTheme.textSecondary,
                      ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMetadataSection() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Metadata',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
            ),
            const SizedBox(height: 16),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: AppTheme.backgroundLight,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: AppTheme.borderLight),
              ),
              child: Text(
                widget.reminder.metadata.toString(),
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      fontFamily: 'monospace',
                    ),
              ),
            ),
          ],
        ),
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

  String _formatDateTime(DateTime date) {
    return '${date.month}/${date.day}/${date.year} ${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}';
  }

  void _handleMenuAction(String action) {
    switch (action) {
      case 'send':
        _sendReminder();
        break;
      case 'mark_sent':
        _markAsSent();
        break;
      case 'mark_read':
        _markAsRead();
        break;
      case 'cancel':
        _cancelReminder();
        break;
      case 'delete':
        _deleteReminder();
        break;
    }
  }

  void _showError(Object e) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Something went wrong: $e'),
        backgroundColor: AppTheme.error,
      ),
    );
  }

  void _sendReminder() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Send Reminder'),
        content: Text('Send reminder "${widget.reminder.title}"?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () async {
              Navigator.of(context).pop();
              try {
                await ref.read(reminderOperationsProvider.notifier).sendReminder(
                      facilityId: widget.reminder.facilityId,
                      reminderId: widget.reminder.id,
                      tenantEmail: widget.reminder.tenantEmail ?? '',
                      tenantPhone: widget.reminder.tenantPhone ?? '',
                      message: widget.reminder.message,
                      channels: widget.reminder.channels,
                    );
                if (!context.mounted) return;
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Reminder sent successfully')),
                );
                context.pop();
              } catch (e) {
                _showError(e);
              }
            },
            child: const Text('Send'),
          ),
        ],
      ),
    );
  }

  void _markAsSent() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Mark as Sent'),
        content: const Text('Mark this reminder as sent?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () async {
              Navigator.of(context).pop();
              try {
                await ref.read(reminderOperationsProvider.notifier).markAsSent(
                      widget.reminder.facilityId,
                      widget.reminder.id,
                    );
                if (!context.mounted) return;
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Reminder marked as sent')),
                );
                context.pop();
              } catch (e) {
                _showError(e);
              }
            },
            child: const Text('Mark as Sent'),
          ),
        ],
      ),
    );
  }

  void _markAsRead() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Mark as Read'),
        content: const Text('Mark this reminder as read?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () async {
              Navigator.of(context).pop();
              try {
                await ref.read(reminderOperationsProvider.notifier).markAsRead(
                      widget.reminder.facilityId,
                      widget.reminder.id,
                    );
                if (!context.mounted) return;
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Reminder marked as read')),
                );
                context.pop();
              } catch (e) {
                _showError(e);
              }
            },
            child: const Text('Mark as Read'),
          ),
        ],
      ),
    );
  }

  void _cancelReminder() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Cancel Reminder'),
        content: const Text('Are you sure you want to cancel this reminder?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('No'),
          ),
          ElevatedButton(
            onPressed: () async {
              Navigator.of(context).pop();
              try {
                await ref.read(reminderOperationsProvider.notifier).cancelReminder(
                      widget.reminder.facilityId,
                      widget.reminder.id,
                    );
                if (!context.mounted) return;
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Reminder cancelled')),
                );
                context.pop();
              } catch (e) {
                _showError(e);
              }
            },
            child: const Text('Yes'),
          ),
        ],
      ),
    );
  }

  void _deleteReminder() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete Reminder'),
        content: const Text('Are you sure you want to delete this reminder? This action cannot be undone.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () async {
              Navigator.of(context).pop();
              try {
                await ref.read(reminderOperationsProvider.notifier).deleteReminder(
                      widget.reminder.facilityId,
                      widget.reminder.id,
                    );
                if (!context.mounted) return;
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Reminder deleted')),
                );
                context.pop();
              } catch (e) {
                _showError(e);
              }
            },
            style: ElevatedButton.styleFrom(backgroundColor: AppTheme.error),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
  }
}
