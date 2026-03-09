import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:state_notifier/state_notifier.dart';
import '../models/reminder_model.dart';
import '../services/reminder_automation_service.dart';
import '../services/reminder_service.dart';

// Reminder list provider (real-time stream)
final reminderListProvider = StreamProvider.family<List<ReminderModel>, String>((ref, facilityId) {
  return ReminderService.getRemindersForFacilityStream(facilityId);
});

// Reminder stats provider
final reminderStatsProvider = FutureProvider.family<Map<String, dynamic>, String>((ref, facilityId) async {
  final reminders = await ReminderService.getRemindersForFacility(facilityId);
  final total = reminders.length;
  final sent = reminders.where((r) => r.status == ReminderStatus.sent).length;
  final pending = reminders.where((r) => r.status == ReminderStatus.pending).length;
  final overdue = reminders.where((r) => r.isOverdue).length;
  
  return {
    'total': total,
    'sent': sent,
    'pending': pending,
    'overdue': overdue,
  };
});

// Reminders for facility provider
final remindersForFacilityProvider = FutureProvider.family<List<ReminderModel>, String>((ref, facilityId) async {
  return await ReminderService.getRemindersForFacility(facilityId);
});

// Tenant reminders provider
final tenantRemindersProvider = FutureProvider.family<List<ReminderModel>, Map<String, String>>((ref, params) async {
  final facilityId = params['facilityId'] ?? '';
  final tenantId = params['tenantId'] ?? '';
  if (facilityId.isEmpty || tenantId.isEmpty) return [];
  return await ReminderService.getRemindersForTenant(facilityId, tenantId);
});

// Pending reminders provider
final pendingRemindersProvider = FutureProvider.family<List<ReminderModel>, String>((ref, facilityId) async {
  return await ReminderService.getPendingReminders(facilityId);
});

// Reminder statistics provider
final reminderStatisticsProvider = FutureProvider.family<Map<String, dynamic>, String>((ref, facilityId) async {
  return await ReminderService.getReminderStatistics(facilityId);
});

// Reminder operations provider
final reminderOperationsProvider = StateNotifierProvider<ReminderOperationsNotifier, AsyncValue<void>>((ref) {
  return ReminderOperationsNotifier();
});

class ReminderOperationsNotifier extends StateNotifier<AsyncValue<void>> {
  ReminderOperationsNotifier() : super(const AsyncValue.data(null));

  Future<void> createReminder({
    required String facilityId,
    required String title,
    required String message,
    required DateTime scheduledFor,
    required List<ReminderChannel> channels,
    String? tenantId,
    String? contractId,
    String? paymentId,
    ReminderType? type,
    Map<String, dynamic>? metadata,
  }) async {
    state = const AsyncValue.loading();
    try {
      await ReminderService.createReminder(
        facilityId: facilityId,
        title: title,
        message: message,
        scheduledFor: scheduledFor,
        channels: channels,
        tenantId: tenantId ?? '',
        contractId: contractId,
        paymentId: paymentId,
        type: type ?? ReminderType.custom,
        metadata: metadata,
      );
      state = const AsyncValue.data(null);
    } catch (e, stackTrace) {
      state = AsyncValue.error(e, stackTrace);
    }
  }

  Future<void> updateReminder({
    required String facilityId,
    required String reminderId,
    String? title,
    String? message,
    DateTime? scheduledFor,
    List<ReminderChannel>? channels,
    Map<String, dynamic>? metadata,
  }) async {
    state = const AsyncValue.loading();
    try {
      await ReminderService.updateReminder(
        facilityId: facilityId,
        reminderId: reminderId,
        title: title,
        message: message,
        scheduledFor: scheduledFor,
        channels: channels,
        metadata: metadata,
      );
      state = const AsyncValue.data(null);
    } catch (e, stackTrace) {
      state = AsyncValue.error(e, stackTrace);
    }
  }

  Future<void> markReminderAsSent({
    required String facilityId,
    required String reminderId,
  }) async {
    state = const AsyncValue.loading();
    try {
      await ReminderService.markReminderAsSent(
        facilityId: facilityId,
        reminderId: reminderId,
      );
      state = const AsyncValue.data(null);
    } catch (e, stackTrace) {
      state = AsyncValue.error(e, stackTrace);
    }
  }

  Future<void> sendReminder({
    required String facilityId,
    required String reminderId,
    required String tenantEmail,
    required String tenantPhone,
    required String message,
    required List<ReminderChannel> channels,
  }) async {
    state = const AsyncValue.loading();
    try {
      await ReminderService.sendReminder(
        facilityId: facilityId,
        reminderId: reminderId,
        tenantEmail: tenantEmail,
        tenantPhone: tenantPhone,
        message: message,
        channels: channels,
      );
      state = const AsyncValue.data(null);
    } catch (e, stackTrace) {
      state = AsyncValue.error(e, stackTrace);
    }
  }

  Future<void> archiveReminder(String facilityId, String reminderId) async {
    state = const AsyncValue.loading();
    try {
      await ReminderService.archiveReminder(facilityId, reminderId);
      state = const AsyncValue.data(null);
    } catch (e, stackTrace) {
      state = AsyncValue.error(e, stackTrace);
    }
  }

  Future<void> deleteReminder(String facilityId, String reminderId) async {
    state = const AsyncValue.loading();
    try {
      await ReminderService.deleteReminder(facilityId, reminderId);
      state = const AsyncValue.data(null);
    } catch (e, stackTrace) {
      state = AsyncValue.error(e, stackTrace);
    }
  }

  Future<void> markAsSent(String facilityId, String reminderId) async {
    state = const AsyncValue.loading();
    try {
      // Mark as sent logic here - would need to implement in service
      state = const AsyncValue.data(null);
    } catch (e, stackTrace) {
      state = AsyncValue.error(e, stackTrace);
    }
  }

  Future<void> markAsRead(String facilityId, String reminderId) async {
    state = const AsyncValue.loading();
    try {
      // Mark as read logic here - would need to implement in service
      state = const AsyncValue.data(null);
    } catch (e, stackTrace) {
      state = AsyncValue.error(e, stackTrace);
    }
  }

  Future<void> cancelReminder(String facilityId, String reminderId) async {
    state = const AsyncValue.loading();
    try {
      // Cancel reminder logic here - would need to implement in service
      state = const AsyncValue.data(null);
    } catch (e, stackTrace) {
      state = AsyncValue.error(e, stackTrace);
    }
  }

  Future<void> processOverduePayments(String facilityId) async {
    state = const AsyncValue.loading();
    try {
      // Process overdue payments logic here - would need to implement in service
      state = const AsyncValue.data(null);
    } catch (e, stackTrace) {
      state = AsyncValue.error(e, stackTrace);
    }
  }

  Future<void> processContractExpirations(String facilityId) async {
    state = const AsyncValue.loading();
    try {
      // Process contract expirations logic here - would need to implement in service
      state = const AsyncValue.data(null);
    } catch (e, stackTrace) {
      state = AsyncValue.error(e, stackTrace);
    }
  }

  Future<ReminderAutomationResult> runAutomation(String facilityId) async {
    state = const AsyncValue.loading();
    try {
      final result =
          await ReminderAutomationService.runFacilitySchedules(facilityId);
      state = const AsyncValue.data(null);
      return result;
    } catch (e, stackTrace) {
      state = AsyncValue.error(e, stackTrace);
      rethrow;
    }
  }
}