import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:state_notifier/state_notifier.dart';
import '../models/messaging_model.dart';
import '../services/messaging_service.dart';
import 'active_facility_provider.dart';
import 'auth_provider.dart';

// Conversations provider (real-time stream)
final conversationsProvider = StreamProvider.family<List<ConversationModel>, String>((ref, facilityId) {
  if (facilityId.isEmpty) return Stream.value([]);
  return MessagingService.streamConversations(facilityId);
});

/// Number of employee-chat conversations with unread activity for the signed-in user (sidebar / tabs).
final employeeChatUnreadConversationCountProvider = Provider.family<int, String>((ref, facilityId) {
  if (facilityId.isEmpty || facilityId == 'all') return 0;
  final uid = ref.watch(authStateProvider).whenOrNull(data: (u) => u?.uid);
  if (uid == null || uid.isEmpty) return 0;
  final conv = ref.watch(conversationsProvider(facilityId));
  return conv.when(
    data: (list) => list.where((c) => c.hasUnreadEmployeeChatFor(uid)).length,
    loading: () => 0,
    error: (_, __) => 0,
  );
});

/// Unread employee-chat count for [activeFacilityIdProvider] (sidebar; skips "all" / empty).
final activeFacilityEmployeeChatUnreadCountProvider = Provider<int>((ref) {
  final facilityId = ref.watch(activeFacilityIdProvider).maybeWhen(
        data: (d) => d,
        orElse: () => null,
      );
  if (facilityId == null || facilityId.isEmpty || facilityId == 'all') return 0;
  return ref.watch(employeeChatUnreadConversationCountProvider(facilityId));
});

/// Facility-scoped chat display names for employee messaging (`employeeChatNames`).
final employeeChatNamesProvider = StreamProvider.family<Map<String, String>, String>((ref, facilityId) {
  if (facilityId.isEmpty || facilityId == 'all') return Stream.value({});
  return MessagingService.streamEmployeeChatNames(facilityId);
});

// Messages provider (real-time stream)
final messagesProvider = StreamProvider.family<List<MessageModel>, (String facilityId, String conversationId)>((ref, params) {
  final facilityId = params.$1;
  final conversationId = params.$2;
  if (facilityId.isEmpty || conversationId.isEmpty) return Stream.value([]);
  return MessagingService.streamMessages(facilityId, conversationId);
});

// Messaging operations provider
final messagingOperationsProvider = StateNotifierProvider<MessagingOperationsNotifier, AsyncValue<void>>((ref) {
  return MessagingOperationsNotifier();
});

class MessagingOperationsNotifier extends StateNotifier<AsyncValue<void>> {
  MessagingOperationsNotifier() : super(const AsyncValue.data(null));

  Future<String> createConversation({
    required String facilityId,
    required String title,
  }) async {
    state = const AsyncValue.loading();
    try {
      final conversationId = await MessagingService.createConversation(
        facilityId: facilityId,
        title: title,
      );
      state = const AsyncValue.data(null);
      return conversationId;
    } catch (e, stackTrace) {
      state = AsyncValue.error(e, stackTrace);
      rethrow;
    }
  }

  Future<void> sendMessage({
    required String facilityId,
    required String conversationId,
    required String text,
  }) async {
    state = const AsyncValue.loading();
    try {
      await MessagingService.sendMessage(
        facilityId: facilityId,
        conversationId: conversationId,
        text: text,
      );
      state = const AsyncValue.data(null);
    } catch (e, stackTrace) {
      state = AsyncValue.error(e, stackTrace);
    }
  }

  Future<void> archiveConversation({
    required String facilityId,
    required String conversationId,
  }) async {
    state = const AsyncValue.loading();
    try {
      await MessagingService.archiveConversation(
        facilityId: facilityId,
        conversationId: conversationId,
      );
      state = const AsyncValue.data(null);
    } catch (e, stackTrace) {
      state = AsyncValue.error(e, stackTrace);
    }
  }

  Future<void> deleteConversation({
    required String facilityId,
    required String conversationId,
  }) async {
    state = const AsyncValue.loading();
    try {
      await MessagingService.deleteConversation(
        facilityId: facilityId,
        conversationId: conversationId,
      );
      state = const AsyncValue.data(null);
    } catch (e, stackTrace) {
      state = AsyncValue.error(e, stackTrace);
    }
  }
}
