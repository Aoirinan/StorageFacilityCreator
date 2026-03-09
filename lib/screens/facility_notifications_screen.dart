import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import '../theme/app_theme.dart';
import '../widgets/modern_page_wrapper.dart';
import '../providers/active_facility_provider.dart';
import '../services/autopay_service.dart';
import '../models/facility_notification_model.dart';

class FacilityNotificationsScreen extends ConsumerWidget {
  const FacilityNotificationsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final facilityIdAsync = ref.watch(activeFacilityIdProvider);

    return facilityIdAsync.when(
      data: (facilityId) {
        if (facilityId == null || facilityId.isEmpty) {
          return ModernPageWrapper(
            currentRoute: '/notifications',
            title: 'Notifications',
            child: const Center(child: Text('Please select a facility')),
          );
        }
        return _NotificationsContent(facilityId: facilityId);
      },
      loading: () => ModernPageWrapper(
        currentRoute: '/notifications',
        title: 'Notifications',
        child: const Center(child: CircularProgressIndicator()),
      ),
      error: (e, _) => ModernPageWrapper(
        currentRoute: '/notifications',
        title: 'Notifications',
        child: Center(child: Text('Error: $e')),
      ),
    );
  }
}

class _NotificationsContent extends StatelessWidget {
  final String facilityId;

  const _NotificationsContent({required this.facilityId});

  @override
  Widget build(BuildContext context) {
    return ModernPageWrapper(
      currentRoute: '/notifications',
      title: 'Notifications',
      child: StreamBuilder(
        stream: AutopayService.watchFacilityNotifications(facilityId),
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting && !snapshot.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) {
            return Center(child: Text('Error: ${snapshot.error}'));
          }
          final docs = snapshot.data?.docs ?? [];
          final notifications = docs.map((d) => FacilityNotificationModel.fromFirestore(d)).toList();
          final unread = notifications.where((n) => n.isUnread).toList();
          if (notifications.isEmpty) {
            return const Center(child: Text('No notifications'));
          }
          return ListView.builder(
            itemCount: notifications.length,
            itemBuilder: (context, index) {
              final n = notifications[index];
              return _NotificationTile(facilityId: facilityId, notification: n);
            },
          );
        },
      ),
    );
  }
}

class _NotificationTile extends StatelessWidget {
  final String facilityId;
  final FacilityNotificationModel notification;

  const _NotificationTile({
    required this.facilityId,
    required this.notification,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      color: notification.isUnread ? AppTheme.primaryBlue.withOpacity(0.06) : null,
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: _typeColor(notification.type).withOpacity(0.2),
          child: Icon(_typeIcon(notification.type), color: _typeColor(notification.type), size: 22),
        ),
        title: Text(
          notification.message,
          style: theme.textTheme.titleSmall?.copyWith(
            fontWeight: notification.isUnread ? FontWeight.w600 : null,
          ),
        ),
        subtitle: Text(
          '${notification.tenantName ?? 'Facility'} • ${DateFormat.yMMMd().add_Hm().format(notification.createdAt)}',
          style: theme.textTheme.bodySmall,
        ),
        trailing: notification.isUnread
            ? TextButton(
                onPressed: () => AutopayService.markNotificationRead(
                  facilityId: facilityId,
                  notificationId: notification.id,
                ),
                child: const Text('Mark read'),
              )
            : null,
      ),
    );
  }

  Color _typeColor(FacilityNotificationType type) {
    switch (type) {
      case FacilityNotificationType.autopayDisabled:
        return AppTheme.error;
      case FacilityNotificationType.autopayEnabled:
        return AppTheme.success;
      case FacilityNotificationType.autopayRequested:
        return AppTheme.warning;
      case FacilityNotificationType.stripeActionRequired:
        return AppTheme.warning;
    }
  }

  IconData _typeIcon(FacilityNotificationType type) {
    switch (type) {
      case FacilityNotificationType.autopayDisabled:
        return Icons.cancel;
      case FacilityNotificationType.autopayEnabled:
        return Icons.check_circle;
      case FacilityNotificationType.autopayRequested:
        return Icons.schedule;
      case FacilityNotificationType.stripeActionRequired:
        return Icons.warning;
    }
  }
}
