import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import '../models/messaging_model.dart';
import 'audit_service.dart';

class MessagingService {
  static final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  static final FirebaseAuth _auth = FirebaseAuth.instance;

  // Create a new group conversation
  static Future<String> createConversation({
    required String facilityId,
    required String title,
  }) async {
    try {
      final user = _auth.currentUser;
      if (user == null) throw Exception('User not authenticated');

      if (kDebugMode) {
        print('🔄 Creating conversation: $title for facility: $facilityId');
      }

      final conversationData = {
        'facilityId': facilityId,
        'title': title,
        'createdAt': FieldValue.serverTimestamp(),
        'createdByUid': user.uid,
        'createdByEmail': user.email ?? '',
        'createdByName': user.displayName ?? user.email?.split('@').first ?? 'Unknown',
        'lastMessageAt': null,
        'lastMessagePreview': null,
        'isActive': true,
        'isPrivate': false,
        'participantUids': [], // Empty for group conversations
      };

      final docRef = await _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('conversations')
          .add(conversationData);

      if (kDebugMode) {
        print('✅ Conversation created with ID: ${docRef.id}');
      }

      return docRef.id;
    } catch (e) {
      if (kDebugMode) {
        print('❌ Error creating conversation: $e');
      }
      rethrow;
    }
  }

  // Create or get a private conversation between two users
  // Uses deterministic ID so both users see the same conversation
  static Future<String> createOrGetPrivateConversation({
    required String facilityId,
    required String otherUserId,
    String? otherUserName,
    String? otherUserEmail,
  }) async {
    try {
      final user = _auth.currentUser;
      if (user == null) throw Exception('User not authenticated');

      if (user.uid == otherUserId) {
        throw Exception('Cannot create conversation with yourself');
      }

      // Create deterministic conversation ID (sort UIDs alphabetically)
      final sortedUids = [user.uid, otherUserId]..sort();
      final conversationId = 'private_${sortedUids[0]}_${sortedUids[1]}';

      if (kDebugMode) {
        print('🔄 Creating/finding private conversation between ${user.uid} and $otherUserId');
      }

      final conversationRef = _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('conversations')
          .doc(conversationId);

      // Try to get existing conversation
      final existingDoc = await conversationRef.get();

      if (existingDoc.exists) {
        if (kDebugMode) {
          print('✅ Found existing private conversation: $conversationId');
        }
        return conversationId;
      }

      // Create new private conversation
      final currentUserName = user.displayName ?? user.email?.split('@').first ?? 'Unknown';
      final otherUserDisplayName = otherUserName ?? otherUserEmail?.split('@').first ?? 'Unknown';

      final conversationData = {
        'facilityId': facilityId,
        'title': otherUserDisplayName, // Default title (will be replaced by UI)
        'createdAt': FieldValue.serverTimestamp(),
        'createdByUid': user.uid,
        'createdByEmail': user.email ?? '',
        'createdByName': currentUserName,
        'lastMessageAt': null,
        'lastMessagePreview': null,
        'isActive': true,
        'isPrivate': true,
        'participantUids': sortedUids,
        'participantNames': {
          user.uid: currentUserName,
          otherUserId: otherUserDisplayName,
        },
      };

      await conversationRef.set(conversationData);

      if (kDebugMode) {
        print('✅ Private conversation created with ID: $conversationId');
      }

      return conversationId;
    } catch (e) {
      if (kDebugMode) {
        print('❌ Error creating private conversation: $e');
      }
      rethrow;
    }
  }

  // Send a message in a conversation
  static Future<String> sendMessage({
    required String facilityId,
    required String conversationId,
    required String text,
  }) async {
    try {
      final user = _auth.currentUser;
      if (user == null) throw Exception('User not authenticated');

      if (kDebugMode) {
        print('🔄 Sending message to conversation: $conversationId');
      }

      final messageData = {
        'conversationId': conversationId,
        'facilityId': facilityId,
        'text': text,
        'createdAt': FieldValue.serverTimestamp(),
        'senderUid': user.uid,
        'senderEmail': user.email ?? '',
        'senderName': user.displayName ?? user.email?.split('@').first ?? 'Unknown',
        'readBy': {user.uid: true}, // Mark as read by sender
        'isActive': true,
      };

      // Add message to conversation
      final messageRef = await _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('conversations')
          .doc(conversationId)
          .collection('messages')
          .add(messageData);

      // Update conversation with last message info
      final preview = text.length > 100 ? '${text.substring(0, 100)}...' : text;
      await _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('conversations')
          .doc(conversationId)
          .update({
        'lastMessageAt': FieldValue.serverTimestamp(),
        'lastMessagePreview': preview,
      });

      if (kDebugMode) {
        print('✅ Message sent with ID: ${messageRef.id}');
      }

      return messageRef.id;
    } catch (e) {
      if (kDebugMode) {
        print('❌ Error sending message: $e');
      }
      rethrow;
    }
  }

  // Stream conversations for a facility
  // Includes both group conversations and private conversations the user participates in
  static Stream<List<ConversationModel>> streamConversations(String facilityId) {
    try {
      final user = _auth.currentUser;
      if (user == null) {
        throw Exception('Not signed in');
      }

      if (kDebugMode) {
        print('🔄 Setting up conversations stream for facility: $facilityId');
      }

      // Query for active conversations
      // Note: We can't order by lastMessageAt directly because it can be null
      // Instead, we'll fetch all and sort in memory
      Query query = _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('conversations')
          .where('isActive', isEqualTo: true);

      return query.snapshots().map((snapshot) {
        final allConversations = snapshot.docs.map((doc) {
          return ConversationModel.fromFirestore(doc);
        }).toList();

        // Filter: Show group conversations (isPrivate == false) OR private conversations where user is a participant
        final conversations = allConversations.where((conv) {
          if (!conv.isPrivate) {
            // Group conversation - show to all
            return true;
          } else {
            // Private conversation - only show if user is a participant
            return conv.participantUids.contains(user.uid);
          }
        }).toList();

        // Sort in memory if we used fallback query
        conversations.sort((a, b) {
          final aDate = a.lastMessageAt ?? a.createdAt;
          final bDate = b.lastMessageAt ?? b.createdAt;
          return bDate.compareTo(aDate);
        });

        if (kDebugMode) {
          print('📡 Stream update: ${conversations.length} conversations for facility: $facilityId (${conversations.where((c) => c.isPrivate).length} private)');
        }

        return conversations;
      });
    } catch (e) {
      if (kDebugMode) {
        print('❌ Error setting up conversations stream: $e');
      }
      rethrow;
    }
  }

  // Stream messages for a conversation
  static Stream<List<MessageModel>> streamMessages(String facilityId, String conversationId) {
    try {
      final user = _auth.currentUser;
      if (user == null) {
        throw Exception('Not signed in');
      }

      if (kDebugMode) {
        print('🔄 Setting up messages stream for conversation: $conversationId');
      }

      Query query = _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('conversations')
          .doc(conversationId)
          .collection('messages')
          .where('isActive', isEqualTo: true);
      
      // Try ordered query, fall back to unordered if index is building
      try {
        query = query.orderBy('createdAt', descending: false); // Ascending for chat order
      } catch (orderingError) {
        if (kDebugMode) {
          print('⚠️ Ordered query not available, using unordered: $orderingError');
        }
      }

      return query.snapshots().map((snapshot) {
        final messages = snapshot.docs.map((doc) {
          return MessageModel.fromFirestore(doc);
        }).toList();

        // Sort in memory if we used fallback query
        messages.sort((a, b) => a.createdAt.compareTo(b.createdAt));

        if (kDebugMode) {
          print('📡 Stream update: ${messages.length} messages for conversation: $conversationId');
        }

        return messages;
      });
    } catch (e) {
      if (kDebugMode) {
        print('❌ Error setting up messages stream: $e');
      }
      rethrow;
    }
  }

  // Mark messages as read
  static Future<void> markAsRead({
    required String facilityId,
    required String conversationId,
  }) async {
    try {
      final user = _auth.currentUser;
      if (user == null) throw Exception('User not authenticated');

      if (kDebugMode) {
        print('🔄 Marking conversation as read: $conversationId');
      }

      // Get all unread messages in the conversation
      final unreadMessages = await _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('conversations')
          .doc(conversationId)
          .collection('messages')
          .where('isActive', isEqualTo: true)
          .where('senderUid', isNotEqualTo: user.uid) // Don't mark own messages
          .get();

      // Batch update to mark messages as read
      final batch = _firestore.batch();
      for (final doc in unreadMessages.docs) {
        final readBy = Map<String, bool>.from(doc.data()['readBy'] ?? {});
        readBy[user.uid] = true;
        
        batch.update(doc.reference, {'readBy': readBy});
      }

      if (unreadMessages.docs.isNotEmpty) {
        await batch.commit();
        
        if (kDebugMode) {
          print('✅ Marked ${unreadMessages.docs.length} messages as read');
        }
      }
    } catch (e) {
      if (kDebugMode) {
        print('❌ Error marking messages as read: $e');
      }
      // Don't rethrow - this is a best-effort operation
    }
  }

  // Archive conversation
  static Future<void> archiveConversation({
    required String facilityId,
    required String conversationId,
  }) async {
    try {
      final user = _auth.currentUser;
      if (user == null) throw Exception('User not authenticated');

      final convRef = _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('conversations')
          .doc(conversationId);
      final beforeSnap = await convRef.get();
      final beforeData = beforeSnap.exists && beforeSnap.data() != null
          ? Map<String, dynamic>.from(beforeSnap.data()!)
          : null;

      await convRef.update({
        'isActive': false,
      });

      await AuditService.logEvent(
        facilityId: facilityId,
        eventType: 'conversation.archived',
        targetType: 'conversation',
        targetId: conversationId,
        before: beforeData,
        after: {'isActive': false},
        metadata: {
          if (beforeData != null && beforeData['title'] != null) 'title': beforeData['title'],
          if (beforeData != null) 'isPrivate': beforeData['isPrivate'],
        },
      );

      if (kDebugMode) {
        print('✅ Conversation archived: $conversationId');
      }
    } catch (e) {
      if (kDebugMode) {
        print('❌ Error archiving conversation: $e');
      }
      rethrow;
    }
  }

  // Delete conversation (permanently)
  static Future<void> deleteConversation({
    required String facilityId,
    required String conversationId,
  }) async {
    try {
      final user = _auth.currentUser;
      if (user == null) throw Exception('User not authenticated');

      final convRef = _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('conversations')
          .doc(conversationId);
      final convSnap = await convRef.get();
      final beforeData = convSnap.exists && convSnap.data() != null
          ? Map<String, dynamic>.from(convSnap.data()!)
          : null;

      // Delete all messages first
      final messagesSnapshot = await convRef.collection('messages').get();

      final batch = _firestore.batch();
      for (final doc in messagesSnapshot.docs) {
        batch.delete(doc.reference);
      }

      batch.delete(convRef);

      await batch.commit();

      await AuditService.logEvent(
        facilityId: facilityId,
        eventType: 'conversation.deleted',
        targetType: 'conversation',
        targetId: conversationId,
        before: beforeData,
        metadata: {
          'messagesDeleted': messagesSnapshot.docs.length,
          if (beforeData != null && beforeData['title'] != null) 'title': beforeData['title'],
          if (beforeData != null) 'isPrivate': beforeData['isPrivate'],
        },
      );

      if (kDebugMode) {
        print('✅ Conversation deleted: $conversationId');
      }
    } catch (e) {
      if (kDebugMode) {
        print('❌ Error deleting conversation: $e');
      }
      rethrow;
    }
  }
}
