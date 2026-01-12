import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:state_notifier/state_notifier.dart';

import '../models/reminder_model.dart';
import '../models/reminder_schedule_model.dart';
import '../services/reminder_service.dart';

final reminderSchedulesProvider =
    StreamProvider.family<List<ReminderScheduleModel>, String>((ref, facilityId) {
  return ReminderService.getReminderSchedulesStream(facilityId);
});

final reminderScheduleOperationsProvider =
    StateNotifierProvider<ReminderScheduleOperationsNotifier, AsyncValue<void>>((ref) {
  return ReminderScheduleOperationsNotifier();
});

class ReminderScheduleOperationsNotifier extends StateNotifier<AsyncValue<void>> {
  ReminderScheduleOperationsNotifier() : super(const AsyncValue.data(null));

  Future<void> createSchedule({
    required String facilityId,
    required String name,
    required ReminderType type,
    required List<ReminderChannel> channels,
    required ReminderSendMode sendMode,
    required int offsetDays,
    required String sendTime,
    required bool autoSend,
    required bool isActive,
    required String titleTemplate,
    required String messageTemplate,
  }) async {
    state = const AsyncValue.loading();
    try {
      await ReminderService.createReminderSchedule(
        facilityId: facilityId,
        name: name,
        type: type,
        channels: channels,
        sendMode: sendMode,
        offsetDays: offsetDays,
        sendTime: sendTime,
        autoSend: autoSend,
        isActive: isActive,
        titleTemplate: titleTemplate,
        messageTemplate: messageTemplate,
      );
      state = const AsyncValue.data(null);
    } catch (error, stackTrace) {
      state = AsyncValue.error(error, stackTrace);
    }
  }

  Future<void> updateSchedule({
    required String facilityId,
    required String scheduleId,
    String? name,
    ReminderType? type,
    List<ReminderChannel>? channels,
    ReminderSendMode? sendMode,
    int? offsetDays,
    String? sendTime,
    bool? autoSend,
    bool? isActive,
    String? titleTemplate,
    String? messageTemplate,
  }) async {
    state = const AsyncValue.loading();
    try {
      await ReminderService.updateReminderSchedule(
        facilityId: facilityId,
        scheduleId: scheduleId,
        name: name,
        type: type,
        channels: channels,
        sendMode: sendMode,
        offsetDays: offsetDays,
        sendTime: sendTime,
        autoSend: autoSend,
        isActive: isActive,
        titleTemplate: titleTemplate,
        messageTemplate: messageTemplate,
      );
      state = const AsyncValue.data(null);
    } catch (error, stackTrace) {
      state = AsyncValue.error(error, stackTrace);
    }
  }

  Future<void> deleteSchedule({
    required String facilityId,
    required String scheduleId,
  }) async {
    state = const AsyncValue.loading();
    try {
      await ReminderService.deleteReminderSchedule(
        facilityId: facilityId,
        scheduleId: scheduleId,
      );
      state = const AsyncValue.data(null);
    } catch (error, stackTrace) {
      state = AsyncValue.error(error, stackTrace);
    }
  }

  Future<void> toggleSchedule({
    required String facilityId,
    required String scheduleId,
    required bool isActive,
  }) async {
    state = const AsyncValue.loading();
    try {
      await ReminderService.toggleReminderSchedule(
        facilityId: facilityId,
        scheduleId: scheduleId,
        isActive: isActive,
      );
      state = const AsyncValue.data(null);
    } catch (error, stackTrace) {
      state = AsyncValue.error(error, stackTrace);
    }
  }
}

