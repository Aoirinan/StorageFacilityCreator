import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import '../models/messaging_model.dart';
import '../models/permission_model.dart';
import 'audit_service.dart';
import 'permission_service.dart';
import 'superadmin_service.dart';

String _participantDisplayLabel(String? name, String? email) {
  final n = name?.trim() ?? '';
  if (n.isNotEmpty && !ConversationModel.isWeakParticipantLabel(n)) {
    return n;
  }
  final e = email?.trim() ?? '';
  if (e.contains('@')) {
    return e;
  }
  if (e.isNotEmpty) {
    return e;
  }
  return 'Teammate';
}

/// Facility subcollection: `facilities/{facilityId}/employeeChatNames/{userId}`.
/// Staff can read; each user can write their own doc; owners/managers can write any.
class MessagingService {
  static final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  static final FirebaseAuth _auth = FirebaseAuth.instance;

  static const int maxEmployeeChatNameLength = 80;

  static CollectionReference<Map<String, dynamic>> _employeeChatNamesCol(
    String facilityId,
  ) =>
      _firestore.collection('facilities').doc(facilityId).collection('employeeChatNames');

  static Future<String?> getEmployeeChatName(String facilityId, String userId) async {
    if (facilityId.isEmpty || userId.isEmpty) return null;
    try {
      final doc = await _employeeChatNamesCol(facilityId).doc(userId).get();
      if (!doc.exists) return null;
      final n = doc.data()?['chatName'] as String?;
      final t = n?.trim() ?? '';
      return t.isEmpty ? null : t;
    } catch (e) {
      if (kDebugMode) {
        print('⚠️ getEmployeeChatName: $e');
      }
      return null;
    }
  }

  static Future<Map<String, String>> getEmployeeChatNamesMap(String facilityId) async {
    if (facilityId.isEmpty || facilityId == 'all') return {};
    try {
      final snap = await _employeeChatNamesCol(facilityId).get();
      final map = <String, String>{};
      for (final doc in snap.docs) {
        final n = doc.data()['chatName'] as String?;
        final t = n?.trim() ?? '';
        if (t.isNotEmpty) map[doc.id] = t;
      }
      return map;
    } catch (e) {
      if (kDebugMode) {
        print('⚠️ getEmployeeChatNamesMap: $e');
      }
      return {};
    }
  }

  static Stream<Map<String, String>> streamEmployeeChatNames(String facilityId) {
    if (facilityId.isEmpty || facilityId == 'all') {
      return Stream.value({});
    }
    return _employeeChatNamesCol(facilityId).snapshots().map((snap) {
      final map = <String, String>{};
      for (final doc in snap.docs) {
        final n = doc.data()['chatName'] as String?;
        final t = n?.trim() ?? '';
        if (t.isNotEmpty) map[doc.id] = t;
      }
      return map;
    });
  }

  /// Clears the nickname when [rawName] is empty (deletes the doc).
  static Future<void> setEmployeeChatName({
    required String facilityId,
    required String targetUserId,
    required String rawName,
  }) async {
    final user = _auth.currentUser;
    if (user == null) throw Exception('User not authenticated');

    final trimmed = rawName.trim();
    if (trimmed.length > maxEmployeeChatNameLength) {
      throw Exception('Display name must be $maxEmployeeChatNameLength characters or fewer.');
    }

    if (user.uid != targetUserId) {
      final check = await PermissionService.hasPermission(
        permission: PermissionType.manageUsers,
        facilityId: facilityId,
      );
      if (!check.hasPermission) {
        throw Exception('Only an owner or manager can set another teammate\'s chat name.');
      }
    }

    final docRef = _employeeChatNamesCol(facilityId).doc(targetUserId);
    if (trimmed.isEmpty) {
      await docRef.delete();
    } else {
      await docRef.set({
        'chatName': trimmed,
        'updatedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
    }

    await _propagateEmployeeChatNameToPrivateConversations(
      facilityId: facilityId,
      userId: targetUserId,
      chatName: trimmed,
    );
  }

  static Future<void> _propagateEmployeeChatNameToPrivateConversations({
    required String facilityId,
    required String userId,
    required String chatName,
  }) async {
    try {
      final snap = await _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('conversations')
          .where('participantUids', arrayContains: userId)
          .get();

      WriteBatch? batch;
      var ops = 0;

      for (final doc in snap.docs) {
        final data = doc.data();
        if (data['isPrivate'] != true) continue;

        batch ??= _firestore.batch();
        final names = _stringMapFromFirestore(data['participantNames']);
        if (chatName.isEmpty) {
          names.remove(userId);
        } else {
          names[userId] = chatName;
        }
        batch.update(doc.reference, {'participantNames': names});
        ops++;
        if (ops >= 450) {
          await batch.commit();
          batch = null;
          ops = 0;
        }
      }
      if (batch != null && ops > 0) {
        await batch.commit();
      }
    } catch (e) {
      if (kDebugMode) {
        print('⚠️ propagate employee chat name: $e');
      }
    }
  }

  static Future<String> resolveSenderDisplayName({
    required String facilityId,
    required String uid,
    String? authDisplayName,
    String? email,
  }) async {
    final stored = await getEmployeeChatName(facilityId, uid);
    if (stored != null && stored.isNotEmpty) return stored;
    return _participantDisplayLabel(authDisplayName, email);
  }

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

  static Map<String, String> _stringMapFromFirestore(dynamic raw) {
    if (raw is! Map) return {};
    return raw.map((k, v) => MapEntry(k.toString(), v?.toString() ?? ''));
  }

  static void _mergeParticipantName(
    Map<String, String> names,
    String uid,
    String proposed,
  ) {
    final prev = names[uid];
    if (prev == null ||
        prev.isEmpty ||
        ConversationModel.isWeakParticipantLabel(prev)) {
      names[uid] = proposed;
    }
  }

  /// Best-effort: refresh stale "Unknown" / missing labels when someone opens the DM again.
  static Future<void> _mergePrivateConversationParticipantFields({
    required DocumentReference<Map<String, dynamic>> conversationRef,
    required Map<String, dynamic>? existingData,
    required String currentUid,
    required String? currentName,
    required String? currentEmail,
    required String otherUid,
    required String? otherName,
    required String? otherEmail,
  }) async {
    final names = _stringMapFromFirestore(existingData?['participantNames']);
    final emails = _stringMapFromFirestore(existingData?['participantEmails']);

    final facilityId = (existingData?['facilityId'] as String?) ?? '';

    final chatCurrent =
        facilityId.isNotEmpty ? await getEmployeeChatName(facilityId, currentUid) : null;
    final chatOther =
        facilityId.isNotEmpty ? await getEmployeeChatName(facilityId, otherUid) : null;

    final newCurrent =
        (chatCurrent != null && chatCurrent.isNotEmpty)
            ? chatCurrent
            : _participantDisplayLabel(currentName, currentEmail);
    final newOther =
        (chatOther != null && chatOther.isNotEmpty)
            ? chatOther
            : _participantDisplayLabel(otherName, otherEmail);

    _mergeParticipantName(names, currentUid, newCurrent);
    _mergeParticipantName(names, otherUid, newOther);

    if ((currentEmail ?? '').isNotEmpty) {
      emails[currentUid] = currentEmail!.trim();
    }
    if ((otherEmail ?? '').isNotEmpty) {
      emails[otherUid] = otherEmail!.trim();
    }

    final title = names[otherUid] ?? newOther;

    try {
      await conversationRef.update({
        'participantNames': names,
        'participantEmails': emails,
        'title': title,
      });
    } catch (e) {
      if (kDebugMode) {
        print('⚠️ Could not enrich private conversation metadata: $e');
      }
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
        await _mergePrivateConversationParticipantFields(
          conversationRef: conversationRef,
          existingData: existingDoc.data(),
          currentUid: user.uid,
          currentName: user.displayName,
          currentEmail: user.email,
          otherUid: otherUserId,
          otherName: otherUserName,
          otherEmail: otherUserEmail,
        );
        return conversationId;
      }

      // Create new private conversation
      final chatSelf = await getEmployeeChatName(facilityId, user.uid);
      final chatOther = await getEmployeeChatName(facilityId, otherUserId);
      final currentUserName = (chatSelf != null && chatSelf.isNotEmpty)
          ? chatSelf
          : _participantDisplayLabel(user.displayName, user.email);
      final otherUserDisplayName = (chatOther != null && chatOther.isNotEmpty)
          ? chatOther
          : _participantDisplayLabel(otherUserName, otherUserEmail);

      final conversationData = {
        'facilityId': facilityId,
        'title': otherUserDisplayName,
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
        'participantEmails': {
          user.uid: user.email ?? '',
          otherUserId: otherUserEmail ?? '',
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

      final senderLabel = await resolveSenderDisplayName(
        facilityId: facilityId,
        uid: user.uid,
        authDisplayName: user.displayName,
        email: user.email,
      );

      final messageData = {
        'conversationId': conversationId,
        'facilityId': facilityId,
        'text': text,
        'createdAt': FieldValue.serverTimestamp(),
        'senderUid': user.uid,
        'senderEmail': user.email ?? '',
        'senderName': senderLabel,
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

  /// Mirrors [isFacilityStaff] / owner-manager checks in [firestore.rules] for employee chat queries.
  static Future<bool> _useFullEmployeeConversationQuery(String facilityId, String uid) async {
    if (SuperAdminService.isSuperAdmin()) return true;
    final snap = await _firestore.collection('facilities').doc(facilityId).get();
    if (!snap.exists) return false;
    final d = snap.data()!;
    if (d['ownerUid'] == uid) return true;
    final managers = d['managers'] as Map<String, dynamic>?;
    if (managers?[uid] == true) return true;
    final roles = d['roles'] as Map<String, dynamic>?;
    final r = roles?[uid];
    if (r is! String) return false;
    return r == 'owner' ||
        r == 'manager' ||
        r == 'employee' ||
        r == 'admin';
  }

  static List<ConversationModel> _mapSortConversationsForUser(
    QuerySnapshot<Map<String, dynamic>> snapshot,
    String uid,
  ) {
    final allConversations =
        snapshot.docs.map(ConversationModel.fromFirestore).toList();
    final conversations = allConversations.where((conv) {
      if (!conv.isPrivate) return true;
      return conv.participantUids.contains(uid);
    }).toList();
    conversations.sort((a, b) {
      final aDate = a.lastMessageAt ?? a.createdAt;
      final bDate = b.lastMessageAt ?? b.createdAt;
      return bDate.compareTo(aDate);
    });
    return conversations;
  }

  /// Viewers are not [isFacilityStaff] in rules; listing all active conversations would include
  /// private threads they cannot read, so Firestore denies the whole query. Use two queries that
  /// only return documents the user is allowed to read.
  static Stream<List<ConversationModel>> _streamConversationsViewerMerged(
    CollectionReference<Map<String, dynamic>> col,
    String uid,
  ) {
    final groupStream = col
        .where('isActive', isEqualTo: true)
        .where('isPrivate', isNotEqualTo: true)
        .snapshots();
    final dmStream = col
        .where('isActive', isEqualTo: true)
        .where('isPrivate', isEqualTo: true)
        .where('participantUids', arrayContains: uid)
        .snapshots();

    return Stream.multi((controller) {
      var groupList = <ConversationModel>[];
      var dmList = <ConversationModel>[];

      void emitMerged() {
        final byId = <String, ConversationModel>{};
        for (final c in groupList) {
          byId[c.id] = c;
        }
        for (final c in dmList) {
          byId[c.id] = c;
        }
        final merged = byId.values.toList()
          ..sort((a, b) {
            final aDate = a.lastMessageAt ?? a.createdAt;
            final bDate = b.lastMessageAt ?? b.createdAt;
            return bDate.compareTo(aDate);
          });
        controller.add(merged);
      }

      controller.add(<ConversationModel>[]);

      final subG = groupStream.listen(
        (snap) {
          groupList = snap.docs
              .map(ConversationModel.fromFirestore)
              .where((c) => !c.isPrivate)
              .toList();
          emitMerged();
        },
        onError: controller.addError,
      );
      final subD = dmStream.listen(
        (snap) {
          dmList = snap.docs.map(ConversationModel.fromFirestore).toList();
          emitMerged();
        },
        onError: controller.addError,
      );

      controller.onCancel = () {
        subG.cancel();
        subD.cancel();
      };
    });
  }

  // Stream conversations for a facility
  // Includes both group conversations and private conversations the user participates in
  static Stream<List<ConversationModel>> streamConversations(String facilityId) {
    final user = _auth.currentUser;
    if (user == null) {
      return Stream.error(Exception('Not signed in'));
    }
    if (facilityId.isEmpty) {
      return Stream.value([]);
    }

    if (kDebugMode) {
      print('🔄 Setting up conversations stream for facility: $facilityId');
    }

    final col = _firestore.collection('facilities').doc(facilityId).collection('conversations');

    return Stream.fromFuture(_useFullEmployeeConversationQuery(facilityId, user.uid)).asyncExpand((fullQuery) {
      if (fullQuery) {
        return col.where('isActive', isEqualTo: true).snapshots().map((snapshot) {
          final conversations = _mapSortConversationsForUser(snapshot, user.uid);
          if (kDebugMode) {
            print(
              '📡 Stream update: ${conversations.length} conversations for facility: $facilityId (${conversations.where((c) => c.isPrivate).length} private)',
            );
          }
          return conversations;
        });
      }
      if (kDebugMode) {
        print('📡 Using split conversation queries (viewer / non-staff) for facility: $facilityId');
      }
      return _streamConversationsViewerMerged(col, user.uid);
    });
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
