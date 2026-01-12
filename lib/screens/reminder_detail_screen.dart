import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../models/reminder_model.dart';
import '../providers/reminder_provider.dart';
import '../theme/app_theme.dart';
import '../widgets/modern_page_wrapper.dart';
import '../services/modern_navigation_service.dart';

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
  @override
  Widget build(BuildContext context) {
    return ModernPageWrapper(
      currentRoute: '/reminders',
      title: 'Reminder ${widget.reminder.id.substring(0, 8)}...',
      onNavigate: (route) {
        ModernNavigationService.navigateToRoute(context, route);
      },
      actions: [
        IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => context.pop(),
          tooltip: 'Back',
        ),
        if (widget.reminder.status == ReminderStatus.pending)
          IconButton(
            icon: const Icon(Icons.send),
            onPressed: _sendReminder,
            tooltip: 'Send Reminder',
          ),
        PopupMenuButton<String>(
          onSelected: _handleMenuAction,
          itemBuilder: (context) => [
            if (widget.reminder.status == ReminderStatus.pending)
              const PopupMenuItem(
                value: 'mark_sent',
                child: ListTile(
                  leading: Icon(Icons.check),
                  title: Text('Mark as Sent'),
                ),
              ),
            if (widget.reminder.status == ReminderStatus.sent && !widget.reminder.isRead)
              const PopupMenuItem(
                value: 'mark_read',
                child: ListTile(
                  leading: Icon(Icons.mark_email_read),
                  title: Text('Mark as Read'),
                ),
              ),
            if (widget.reminder.status == ReminderStatus.pending)
              const PopupMenuItem(
                value: 'cancel',
                child: ListTile(
                  leading: Icon(Icons.cancel),
                  title: Text('Cancel'),
                ),
              ),
            const PopupMenuItem(
              value: 'delete',
              child: ListTile(
                leading: Icon(Icons.delete),
                title: Text('Delete'),
              ),
            ),
          ],
        ),
      ],
      child: SingleChildScrollView(
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
      ),
    );
  }

  Widget _buildStatusCard() {
    return Card(
      color: _getStatusColor(widget.reminder.status).withOpacity(0.1),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
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
          ],
        ),
      ),
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
              await ref.read(reminderOperationsProvider.notifier).sendReminder(
                facilityId: widget.reminder.facilityId,
                reminderId: widget.reminder.id,
                tenantEmail: widget.reminder.tenantEmail ?? '',
                tenantPhone: widget.reminder.tenantPhone ?? '',
                message: widget.reminder.message,
                channels: widget.reminder.channels,
              );
              if (mounted) {
                Navigator.of(context).pop();
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Reminder sent successfully')),
                );
              }
            },
            child: const Text('Send'),
          ),
        ],
      ),
    );
  }

  void _handleMenuAction(String action) {
    switch (action) {
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
              await ref.read(reminderOperationsProvider.notifier).markAsSent(widget.reminder.facilityId, widget.reminder.id);
              if (mounted) {
                Navigator.of(context).pop();
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Reminder marked as sent')),
                );
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
              await ref.read(reminderOperationsProvider.notifier).markAsRead(widget.reminder.facilityId, widget.reminder.id);
              if (mounted) {
                Navigator.of(context).pop();
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Reminder marked as read')),
                );
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
              await ref.read(reminderOperationsProvider.notifier).cancelReminder(widget.reminder.facilityId, widget.reminder.id);
              if (mounted) {
                Navigator.of(context).pop();
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Reminder cancelled')),
                );
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
              await ref.read(reminderOperationsProvider.notifier).deleteReminder(widget.reminder.facilityId, widget.reminder.id);
              if (mounted) {
                Navigator.of(context).pop();
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Reminder deleted')),
                );
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
