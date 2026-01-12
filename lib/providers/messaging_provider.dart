import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:state_notifier/state_notifier.dart';
import '../models/messaging_model.dart';
import '../services/messaging_service.dart';

// Conversations provider (real-time stream)
final conversationsProvider = StreamProvider.family<List<ConversationModel>, String>((ref, facilityId) {
  if (facilityId.isEmpty) return Stream.value([]);
  return MessagingService.streamConversations(facilityId);
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

  Future<void> markAsRead({
    required String facilityId,
    required String conversationId,
  }) async {
    state = const AsyncValue.loading();
    try {
      await MessagingService.markAsRead(
        facilityId: facilityId,
        conversationId: conversationId,
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
