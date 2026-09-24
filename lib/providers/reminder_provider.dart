import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:state_notifier/state_notifier.dart';
import '../models/reminder_model.dart';
import '../services/reminder_automation_service.dart';
import '../services/reminder_service.dart';
import 'package:sfcapp/utils/error_message_helper.dart';

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

/// A send that reached no channel: nothing went to the tenant.
class ReminderNotSentException implements UserFacingException {
  const ReminderNotSentException();

  @override
  String get message =>
      'The reminder was not sent: no channel (email, SMS) went through.';

  @override
  String toString() => message;
}

/// A send only on channels that cannot send yet (push, in-app): nothing
/// was tried. They used to count as delivered, so the page said "Reminder
/// sent successfully" and the reminder was marked sent via in-app with
/// nothing sent to the tenant.
class ReminderChannelNotAvailable implements UserFacingException {
  const ReminderChannelNotAvailable(this.channels);

  final List<ReminderChannel> channels;

  @override
  String get message =>
      '${_channelNames(channels)} reminders are not available yet, so '
      'nothing was sent. Send it by email or SMS instead.';

  @override
  String toString() => message;
}

/// A send that went out, but recording it as sent failed. It is not "not
/// sent": that invited a resend, a duplicate email or text to the tenant.
class ReminderNotRecordedException implements UserFacingException {
  const ReminderNotRecordedException(this.delivered);

  /// How it went out, e.g. ['email'].
  final List<String> delivered;

  @override
  String get message =>
      'The reminder went out (${delivered.join(', ')}), but saving it as '
      'sent failed, so it may still show as not sent. Check the '
      "reminder's status before sending it again.";

  @override
  String toString() => message;
}

String _channelNames(List<ReminderChannel> channels) {
  final names = channels.map((c) => c.displayName).toSet().toList();
  if (names.length <= 1) return names.join();
  return '${names.sublist(0, names.length - 1).join(', ')} and ${names.last}';
}

/// Throws unless [result] went out and was recorded.
void throwUnlessReminderSent(ReminderSendResult result) {
  if (!result.sent) {
    if (result.failed.isEmpty && result.unavailable.isNotEmpty) {
      throw ReminderChannelNotAvailable(result.unavailable);
    }
    throw const ReminderNotSentException();
  }
  if (result.recordError != null) {
    throw ReminderNotRecordedException(result.delivered);
  }
}

/// What to tell the operator about a send that went out: how, and any
/// channel it did not go out on.
String reminderSentMessage(ReminderSendResult result) => [
      'Reminder sent (${result.delivered.join(', ')}).',
      if (result.failed.isNotEmpty)
        '${_channelNames(result.failed)} did not go through.',
      if (result.unavailable.isNotEmpty)
        '${_channelNames(result.unavailable)} reminders are not available '
            'yet, so it did not go out that way.',
    ].join(' ');

/// Each method records a failure in [state] and rethrows it. They used to
/// only record it, so a page that awaited one and then said "sent",
/// "cancelled" or "deleted" said so when nothing had happened.
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
      rethrow;
    }
  }

  Future<void> updateReminder({
    required String facilityId,
    required String reminderId,
    ReminderStatus? status,
    String? title,
    String? message,
    DateTime? scheduledFor,
    DateTime? readAt,
    List<ReminderChannel>? channels,
    Map<String, dynamic>? metadata,
  }) async {
    state = const AsyncValue.loading();
    try {
      await ReminderService.updateReminder(
        facilityId: facilityId,
        reminderId: reminderId,
        status: status,
        title: title,
        message: message,
        scheduledFor: scheduledFor,
        readAt: readAt,
        channels: channels,
        metadata: metadata,
      );
      state = const AsyncValue.data(null);
    } catch (e, stackTrace) {
      state = AsyncValue.error(e, stackTrace);
      rethrow;
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
      rethrow;
    }
  }

  /// Sends the reminder and returns what went out. Throws when nothing
  /// went out ([ReminderNotSentException], [ReminderChannelNotAvailable])
  /// or it went out but was not recorded ([ReminderNotRecordedException]).
  Future<ReminderSendResult> sendReminder({
    required String facilityId,
    required String reminderId,
    required String tenantEmail,
    required String tenantPhone,
    required String message,
    required List<ReminderChannel> channels,
  }) async {
    state = const AsyncValue.loading();
    try {
      final result = await ReminderService.sendReminder(
        facilityId: facilityId,
        reminderId: reminderId,
        tenantEmail: tenantEmail,
        tenantPhone: tenantPhone,
        message: message,
        channels: channels,
      );
      // sendReminder catches its own failures, and its false was ignored:
      // the page said "Reminder sent" when nothing went out.
      throwUnlessReminderSent(result);
      state = const AsyncValue.data(null);
      return result;
    } catch (e, stackTrace) {
      state = AsyncValue.error(e, stackTrace);
      rethrow;
    }
  }

  Future<void> archiveReminder(String facilityId, String reminderId) async {
    state = const AsyncValue.loading();
    try {
      await ReminderService.archiveReminder(facilityId, reminderId);
      state = const AsyncValue.data(null);
    } catch (e, stackTrace) {
      state = AsyncValue.error(e, stackTrace);
      rethrow;
    }
  }

  Future<void> deleteReminder(String facilityId, String reminderId) async {
    state = const AsyncValue.loading();
    try {
      await ReminderService.deleteReminder(facilityId, reminderId);
      state = const AsyncValue.data(null);
    } catch (e, stackTrace) {
      state = AsyncValue.error(e, stackTrace);
      rethrow;
    }
  }

  Future<void> markAsSent(String facilityId, String reminderId) async {
    state = const AsyncValue.loading();
    try {
      await ReminderService.markReminderAsSent(
        facilityId: facilityId,
        reminderId: reminderId,
      );
      state = const AsyncValue.data(null);
    } catch (e, stackTrace) {
      state = AsyncValue.error(e, stackTrace);
      rethrow;
    }
  }

  Future<void> markAsRead(String facilityId, String reminderId) async {
    state = const AsyncValue.loading();
    try {
      await ReminderService.updateReminder(
        facilityId: facilityId,
        reminderId: reminderId,
        readAt: DateTime.now(),
      );
      state = const AsyncValue.data(null);
    } catch (e, stackTrace) {
      state = AsyncValue.error(e, stackTrace);
      rethrow;
    }
  }

  Future<void> cancelReminder(String facilityId, String reminderId) async {
    state = const AsyncValue.loading();
    try {
      await ReminderService.updateReminder(
        facilityId: facilityId,
        reminderId: reminderId,
        status: ReminderStatus.cancelled,
      );
      state = const AsyncValue.data(null);
    } catch (e, stackTrace) {
      state = AsyncValue.error(e, stackTrace);
      rethrow;
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