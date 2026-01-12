import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import '../models/sms_conversation_model.dart';
import '../models/sms_message_model.dart';
import 'sms_service.dart';

/// Service for managing SMS conversations
class SMSConversationService {
  static final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  static final FirebaseAuth _auth = FirebaseAuth.instance;

  /// Get all SMS conversations for a facility
  static Future<List<SMSConversationModel>> getConversationsForFacility({
    required String facilityId,
    int limit = 50,
  }) async {
    try {
      final user = _auth.currentUser;
      if (user == null) throw Exception('Not signed in');

      if (kDebugMode) {
        print('🔄 [SMSConversation] Getting conversations for facility: $facilityId');
      }

      // Get all conversations (can't order by nullable lastMessageAt in Firestore)
      // We'll sort in memory instead
      final snapshot = await _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('smsConversations')
          .get();

      // Convert to models and sort in memory by lastMessageAt (handle nulls)
      final conversations = snapshot.docs
          .map((doc) {
            try {
              return SMSConversationModel.fromFirestore(doc);
            } catch (e) {
              if (kDebugMode) {
                print('⚠️ [SMSConversation] Error parsing conversation ${doc.id}: $e');
              }
              return null;
            }
          })
          .whereType<SMSConversationModel>()
          .toList();
      
      // Sort by lastMessageAt (or createdAt if null), descending
      conversations.sort((a, b) {
        final aDate = a.lastMessageAt ?? a.createdAt;
        final bDate = b.lastMessageAt ?? b.createdAt;
        return bDate.compareTo(aDate); // Descending order (newest first)
      });
      
      // Return limited results
      final limitedConversations = conversations.take(limit).toList();

      if (kDebugMode) {
        print('✅ [SMSConversation] Retrieved ${limitedConversations.length} conversations');
      }

      return limitedConversations;
    } catch (e) {
      if (kDebugMode) {
        print('❌ [SMSConversation] Error getting conversations: $e');
      }
      rethrow;
    }
  }

  /// Get SMS conversation for a specific tenant
  static Future<SMSConversationModel?> getConversationForTenant({
    required String facilityId,
    required String tenantId,
    required String phoneNumber,
  }) async {
    try {
      final snapshot = await _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('smsConversations')
          .where('tenantId', isEqualTo: tenantId)
          .where('phoneNumber', isEqualTo: phoneNumber)
          .limit(1)
          .get();

      if (snapshot.docs.isEmpty) {
        return null;
      }

      return SMSConversationModel.fromFirestore(snapshot.docs.first);
    } catch (e) {
      if (kDebugMode) {
        print('❌ [SMSConversation] Error getting conversation: $e');
      }
      return null;
    }
  }

  /// Get messages for a conversation
  static Future<List<SMSMessageModel>> getMessagesForConversation({
    required String facilityId,
    required String conversationId,
    int limit = 100,
  }) async {
    try {
      final snapshot = await _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('smsConversations')
          .doc(conversationId)
          .collection('messages')
          .orderBy('timestamp', descending: true)
          .limit(limit)
          .get();

      final messages = snapshot.docs
          .map((doc) => SMSMessageModel.fromFirestore(doc))
          .toList();

      // Reverse to show oldest first (snapshot is ordered descending by timestamp)
      return messages.reversed.toList();
    } catch (e) {
      if (kDebugMode) {
        print('❌ [SMSConversation] Error getting messages: $e');
      }
      rethrow;
    }
  }

  /// Send reply to a conversation
  static Future<SMSResult> sendReply({
    required String facilityId,
    required String conversationId,
    required String tenantId,
    required String phoneNumber,
    required String message,
  }) async {
    try {
      final user = _auth.currentUser;
      if (user == null) throw Exception('Not signed in');

      if (kDebugMode) {
        print('🔄 [SMSConversation] Sending reply to conversation: $conversationId');
      }

      // Send SMS via existing service
      final result = await SMSService.sendSMS(
        to: phoneNumber,
        message: message,
        facilityId: facilityId,
        tenantId: tenantId,
        relatedEntityType: 'sms_conversation',
        relatedEntityId: conversationId,
      );

      if (result.success && result.messageId != null) {
        // Store outgoing message in conversation
        await _storeOutgoingMessage(
          facilityId: facilityId,
          conversationId: conversationId,
          tenantId: tenantId,
          phoneNumber: phoneNumber,
          message: message,
          messageSid: result.messageId!,
        );

        // Update conversation
        await _updateConversationAfterMessage(
          facilityId: facilityId,
          conversationId: conversationId,
          lastMessage: message,
          direction: SMSDirection.outgoing,
        );
      }

      if (kDebugMode) {
        print('✅ [SMSConversation] Reply sent successfully');
      }

      return result;
    } catch (e) {
      if (kDebugMode) {
        print('❌ [SMSConversation] Error sending reply: $e');
      }
      return SMSResult(
        success: false,
        error: 'Failed to send reply: $e',
      );
    }
  }

  /// Mark messages as read
  static Future<void> markMessagesAsRead({
    required String facilityId,
    required String conversationId,
  }) async {
    try {
      final user = _auth.currentUser;
      if (user == null) throw Exception('Not signed in');

      // Get all unread messages
      final unreadSnapshot = await _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('smsConversations')
          .doc(conversationId)
          .collection('messages')
          .where('read', isEqualTo: false)
          .where('direction', isEqualTo: 'incoming')
          .get();

      // Update all unread messages
      final batch = _firestore.batch();
      final now = DateTime.now();

      for (final doc in unreadSnapshot.docs) {
        batch.update(doc.reference, {
          'read': true,
          'readAt': Timestamp.fromDate(now),
        });
      }

      await batch.commit();

      // Update conversation unread count
      await _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('smsConversations')
          .doc(conversationId)
          .update({
        'unreadCount': 0,
        'updatedAt': FieldValue.serverTimestamp(),
      });

      if (kDebugMode) {
        print('✅ [SMSConversation] Marked ${unreadSnapshot.docs.length} messages as read');
      }
    } catch (e) {
      if (kDebugMode) {
        print('❌ [SMSConversation] Error marking messages as read: $e');
      }
      rethrow;
    }
  }

  /// Get unread count for a facility
  static Future<int> getUnreadCountForFacility({
    required String facilityId,
  }) async {
    try {
      final snapshot = await _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('smsConversations')
          .get();

      int totalUnread = 0;
      for (final doc in snapshot.docs) {
        final data = doc.data();
        final unreadCount = data['unreadCount'];
        totalUnread += (unreadCount is int ? unreadCount : (unreadCount as num?)?.toInt() ?? 0);
      }

      return totalUnread;
    } catch (e) {
      if (kDebugMode) {
        print('❌ [SMSConversation] Error getting unread count: $e');
      }
      return 0;
    }
  }

  /// Store outgoing message in conversation
  static Future<void> _storeOutgoingMessage({
    required String facilityId,
    required String conversationId,
    required String tenantId,
    required String phoneNumber,
    required String message,
    required String messageSid,
  }) async {
    try {
      await _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('smsConversations')
          .doc(conversationId)
          .collection('messages')
          .add({
        'direction': 'outgoing',
        'phoneNumber': phoneNumber,
        'body': message,
        'status': 'sent',
        'messageSid': messageSid,
        'timestamp': FieldValue.serverTimestamp(),
        'read': true, // Outgoing messages are automatically read
      });
    } catch (e) {
      if (kDebugMode) {
        print('❌ [SMSConversation] Error storing outgoing message: $e');
      }
      rethrow;
    }
  }

  /// Update conversation after message
  static Future<void> _updateConversationAfterMessage({
    required String facilityId,
    required String conversationId,
    required String lastMessage,
    required SMSDirection direction,
  }) async {
    try {
      await _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('smsConversations')
          .doc(conversationId)
          .update({
        'lastMessage': lastMessage.length > 100 ? lastMessage.substring(0, 100) : lastMessage,
        'lastMessageAt': FieldValue.serverTimestamp(),
        'lastMessageDirection': direction.name,
        'updatedAt': FieldValue.serverTimestamp(),
      });
    } catch (e) {
      if (kDebugMode) {
        print('❌ [SMSConversation] Error updating conversation: $e');
      }
      rethrow;
    }
  }
}

