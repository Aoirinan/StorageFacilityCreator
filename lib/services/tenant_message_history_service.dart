import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import '../models/tenant_message_history_model.dart';
import '../services/debug_logger.dart';
import 'facility_service.dart';

/// Service for retrieving all messages sent to tenants
class TenantMessageHistoryService {
  static final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  static final FirebaseAuth _auth = FirebaseAuth.instance;

  /// Get all messages sent to tenants for a facility
  /// Queries from unified messageLogs collection
  static Future<List<TenantMessageHistoryModel>> getAllTenantMessages({
    required String facilityId,
    String? tenantId, // Optional: filter by specific tenant
    String? channel, // Optional: filter by channel ('email' | 'sms')
    String? status, // Optional: filter by status ('queued' | 'sent' | 'failed')
    String? source, // Optional: filter by source ('manual' | 'bulk' | 'automation')
    DateTime? startDate, // Optional: filter by start date
    DateTime? endDate, // Optional: filter by end date
    int limit = 500, // Default limit
  }) async {
    try {
      // #region agent log
      DebugLogger.log(
        hypothesisId: 'H4',
        location: 'tenant_message_history_service.dart:getAllTenantMessages',
        message: 'Fetching all tenant messages from messageLogs',
        data: {
          'facilityId': facilityId,
          'tenantId': tenantId,
          'channel': channel,
          'status': status,
          'source': source,
          'limit': limit,
        },
      );
      // #endregion

      final user = _auth.currentUser;
      if (user == null) throw Exception('Not signed in');

      // Query messageLogs collection
      Query query = _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('messageLogs')
          .where('direction', isEqualTo: 'outbound');

      // Apply filters
      if (tenantId != null) {
        query = query.where('tenantId', isEqualTo: tenantId);
      }
      if (channel != null) {
        query = query.where('channel', isEqualTo: channel);
      }
      if (status != null) {
        query = query.where('status', isEqualTo: status);
      }
      if (source != null) {
        query = query.where('source', isEqualTo: source);
      }
      if (startDate != null) {
        query = query.where('createdAt', isGreaterThanOrEqualTo: Timestamp.fromDate(startDate));
      }
      if (endDate != null) {
        query = query.where('createdAt', isLessThanOrEqualTo: Timestamp.fromDate(endDate));
      }

      // Order by createdAt descending (newest first)
      query = query.orderBy('createdAt', descending: true).limit(limit);

      final snapshot = await query.get();

      // Convert to models
      final messages = snapshot.docs
          .map((doc) => TenantMessageHistoryModel.fromFirestore(doc))
          .toList();

      // Load tenant names for messages that don't have them
      final messagesWithNames = await _enrichMessagesWithTenantNames(facilityId, messages);

      // #region agent log
      DebugLogger.log(
        hypothesisId: 'H4',
        location: 'tenant_message_history_service.dart:getAllTenantMessages',
        message: 'Fetched messages from messageLogs',
        data: {'count': messagesWithNames.length},
      );
      // #endregion

      return messagesWithNames;
    } catch (e) {
      if (kDebugMode) {
        print('❌ [TenantMessageHistory] Error getting messages: $e');
      }
      rethrow;
    }
  }

  /// Stream all messages sent to tenants across all user facilities
  /// Used when "All Facilities" is selected in Message History
  static Stream<List<TenantMessageHistoryModel>> streamAllTenantMessagesForAllFacilities({
    int limitPerFacility = 200,
    int totalLimit = 500,
  }) {
    const pollInterval = Duration(seconds: 30);
    Future<List<TenantMessageHistoryModel>> fetchAll() async {
      final facilities = await FacilityService.getUserFacilities();
      if (facilities.isEmpty) return [];
      final allMessages = <TenantMessageHistoryModel>[];
      for (final facility in facilities) {
        try {
          final messages = await getAllTenantMessages(
            facilityId: facility.id,
            limit: limitPerFacility,
          );
          allMessages.addAll(messages);
        } catch (e) {
          if (kDebugMode) {
            print('⚠️ [TenantMessageHistory] Error fetching for ${facility.name}: $e');
          }
        }
      }
      allMessages.sort((a, b) => b.createdAt.compareTo(a.createdAt));
      return allMessages.take(totalLimit).toList();
    }
    return Stream.fromFuture(fetchAll()).asyncExpand(
      (_) => Stream.periodic(pollInterval).asyncMap((_) => fetchAll()),
    );
  }

  /// Stream all messages sent to tenants for a facility (real-time updates)
  /// Queries from unified messageLogs collection
  static Stream<List<TenantMessageHistoryModel>> streamAllTenantMessages({
    required String facilityId,
    String? tenantId, // Optional: filter by specific tenant
    String? channel, // Optional: filter by channel ('email' | 'sms')
    String? status, // Optional: filter by status ('queued' | 'sent' | 'failed')
    String? source, // Optional: filter by source ('manual' | 'bulk' | 'automation')
    DateTime? startDate, // Optional: filter by start date
    DateTime? endDate, // Optional: filter by end date
    int limit = 500, // Default limit
  }) {
    final user = _auth.currentUser;
    if (user == null) {
      return Stream.error(Exception('Not signed in'));
    }

    try {
      // Query messageLogs collection
      Query query = _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('messageLogs')
          .where('direction', isEqualTo: 'outbound');

      // Apply filters
      if (tenantId != null) {
        query = query.where('tenantId', isEqualTo: tenantId);
      }
      if (channel != null) {
        query = query.where('channel', isEqualTo: channel);
      }
      if (status != null) {
        query = query.where('status', isEqualTo: status);
      }
      if (source != null) {
        query = query.where('source', isEqualTo: source);
      }
      if (startDate != null) {
        query = query.where('createdAt', isGreaterThanOrEqualTo: Timestamp.fromDate(startDate));
      }
      if (endDate != null) {
        query = query.where('createdAt', isLessThanOrEqualTo: Timestamp.fromDate(endDate));
      }

      // Order by createdAt descending (newest first)
      query = query.orderBy('createdAt', descending: true).limit(limit);

      if (kDebugMode) {
        print('📡 [TenantMessageHistory] Starting stream for facility: $facilityId');
      }

      // Return stream that automatically updates when messages change
      return query.snapshots().asyncMap((snapshot) async {
        if (kDebugMode) {
          print('📡 [TenantMessageHistory] Stream update: ${snapshot.docs.length} messages');
        }

        try {
          // Convert to models
          final messages = snapshot.docs
              .map((doc) {
                try {
                  return TenantMessageHistoryModel.fromFirestore(doc);
                } catch (e) {
                  if (kDebugMode) {
                    print('⚠️ [TenantMessageHistory] Error parsing document ${doc.id}: $e');
                  }
                  return null;
                }
              })
              .whereType<TenantMessageHistoryModel>()
              .toList();

          // Load tenant names for messages that don't have them
          // Don't let enrichment errors break the stream
          try {
            final messagesWithNames = await _enrichMessagesWithTenantNames(facilityId, messages);
            if (kDebugMode) {
              print('✅ [TenantMessageHistory] Stream update complete: ${messagesWithNames.length} messages');
            }
            return messagesWithNames;
          } catch (e) {
            if (kDebugMode) {
              print('⚠️ [TenantMessageHistory] Error enriching messages, returning without names: $e');
            }
            // Return messages even if enrichment fails
            return messages;
          }
        } catch (e) {
          if (kDebugMode) {
            print('❌ [TenantMessageHistory] Error processing snapshot: $e');
          }
          // Return empty list on error to keep stream alive
          return <TenantMessageHistoryModel>[];
        }
      }).handleError((error) {
        if (kDebugMode) {
          print('❌ [TenantMessageHistory] Stream error: $error');
        }
        // Re-throw to let StreamProvider handle it
        throw error;
      });
    } catch (e) {
      if (kDebugMode) {
        print('❌ [TenantMessageHistory] Error setting up stream: $e');
      }
      return Stream.error(e);
    }
  }

  /// Enrich messages with tenant names if they're missing
  static Future<List<TenantMessageHistoryModel>> _enrichMessagesWithTenantNames(
    String facilityId,
    List<TenantMessageHistoryModel> messages,
  ) async {
    // Find messages that need tenant names
    final tenantIdsToLoad = <String>{};
    for (final message in messages) {
      if (message.tenantId != null && 
          message.tenantId!.isNotEmpty && 
          (message.tenantName == null || message.tenantName!.isEmpty)) {
        tenantIdsToLoad.add(message.tenantId!);
      }
    }

    if (tenantIdsToLoad.isEmpty) {
      return messages; // All messages already have names
    }

    // Load tenant names
    final tenantNames = await _loadTenantNames(
      facilityId: facilityId,
      tenantIds: tenantIdsToLoad,
    );

    // Update messages with tenant names
    return messages.map((message) {
      if (message.tenantId != null && 
          message.tenantId!.isNotEmpty && 
          (message.tenantName == null || message.tenantName!.isEmpty)) {
        final tenantName = tenantNames[message.tenantId!];
        if (tenantName != null) {
          return TenantMessageHistoryModel(
            id: message.id,
            facilityId: message.facilityId,
            tenantId: message.tenantId,
            tenantName: tenantName,
            tenantPhone: message.tenantPhone,
            tenantEmail: message.tenantEmail,
            type: message.type,
            title: message.title,
            message: message.message,
            sentAt: message.sentAt,
            createdAt: message.createdAt,
            status: message.status,
            statusMessage: message.statusMessage,
            channels: message.channels,
            messageId: message.messageId,
            conversationId: message.conversationId,
            relatedEntityId: message.relatedEntityId,
            relatedEntityType: message.relatedEntityType,
            channel: message.channel,
            direction: message.direction,
            source: message.source,
            templateId: message.templateId,
            subject: message.subject,
            previewText: message.previewText,
            provider: message.provider,
            providerMessageId: message.providerMessageId,
            errorCode: message.errorCode,
            errorMessage: message.errorMessage,
            createdByUid: message.createdByUid,
            createdByEmail: message.createdByEmail,
          );
        }
      }
      return message;
    }).toList();
  }

  /// Fetch all SMS messages for a facility
  static Future<List<SMSMessageData>> _fetchSMSMessages({
    required String facilityId,
    String? tenantId,
  }) async {
    try {
      // Get all SMS conversations for the facility
      final conversationsSnapshot = await _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('smsConversations')
          .get();

      final allSMSMessages = <SMSMessageData>[];

      // Fetch messages from each conversation
      for (final conversationDoc in conversationsSnapshot.docs) {
        final conversationData = conversationDoc.data() as Map<String, dynamic>? ?? {};
        final conversationTenantId = conversationData['tenantId'] as String?;

        // Filter by tenantId if provided
        if (tenantId != null && conversationTenantId != tenantId) {
          continue;
        }

        // Get all messages for this conversation
        final messagesSnapshot = await _firestore
            .collection('facilities')
            .doc(facilityId)
            .collection('smsConversations')
            .doc(conversationDoc.id)
            .collection('messages')
            .where('direction', isEqualTo: 'outgoing') // Only outgoing messages
            .orderBy('timestamp', descending: true)
            .limit(1000) // Limit per conversation to avoid timeout
            .get();

        for (final messageDoc in messagesSnapshot.docs) {
          final messageData = messageDoc.data() as Map<String, dynamic>? ?? {};
          allSMSMessages.add(
            SMSMessageData(
              id: messageDoc.id,
              conversationId: conversationDoc.id,
              facilityId: facilityId,
              tenantId: conversationTenantId ?? '',
              phoneNumber: messageData['phoneNumber'] ?? '',
              body: messageData['body'] ?? '',
              status: messageData['status'] ?? 'sent',
              messageSid: messageData['messageSid'],
              timestamp: (messageData['timestamp'] as Timestamp?)?.toDate() ?? DateTime.now(),
            ),
          );
        }
      }

      return allSMSMessages;
    } catch (e) {
      if (kDebugMode) {
        print('❌ [TenantMessageHistory] Error fetching SMS messages: $e');
      }
      return [];
    }
  }

  /// Fetch all reminders for a facility
  static Future<List<ReminderData>> _fetchReminders({
    required String facilityId,
    String? tenantId,
  }) async {
    try {
      Query query = _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('reminders')
          .where('isActive', isEqualTo: true)
          .where('status', whereIn: ['sent', 'failed']); // Only sent or failed reminders

      if (tenantId != null) {
        query = query.where('tenantId', isEqualTo: tenantId);
      }

      final remindersSnapshot = await query
          .orderBy('sentAt', descending: true)
          .limit(1000) // Limit to avoid timeout
          .get();

      return remindersSnapshot.docs.map((doc) {
        final data = doc.data() as Map<String, dynamic>? ?? {};
        // Channels are stored as enum names (e.g., 'sms', 'email')
        final channelsRaw = (data['channels'] as List<dynamic>?) ?? [];
        final channels = channelsRaw
            .map((c) => c.toString().toLowerCase())
            .where((c) => c == 'sms' || c == 'email') // Only SMS and Email
            .toList();
        return ReminderData(
          id: doc.id,
          facilityId: facilityId,
          tenantId: data['tenantId'] ?? '',
          contractId: data['contractId'],
          paymentId: data['paymentId'],
          tenantEmail: data['tenantEmail'],
          tenantPhone: data['tenantPhone'],
          channels: channels,
          title: data['title'] ?? '',
          message: data['message'] ?? '',
          createdAt: (data['createdAt'] as Timestamp?)?.toDate() ?? DateTime.now(),
          sentAt: (data['sentAt'] as Timestamp?)?.toDate(),
          status: data['status'] ?? 'pending',
        );
      }).toList();
    } catch (e) {
      if (kDebugMode) {
        print('❌ [TenantMessageHistory] Error fetching reminders: $e');
      }
      return [];
    }
  }

  /// Load tenant names for display
  static Future<Map<String, String>> _loadTenantNames({
    required String facilityId,
    required Set<String> tenantIds,
  }) async {
    final names = <String, String>{};
    
    if (tenantIds.isEmpty) return names;

    try {
      // Batch fetch tenants (limit to 30 per query due to Firestore limits)
      final tenantIdList = tenantIds.toList();
      for (var i = 0; i < tenantIdList.length; i += 30) {
        final batch = tenantIdList.skip(i).take(30).toList();
        final snapshot = await _firestore
            .collection('facilities')
            .doc(facilityId)
            .collection('tenants')
            .where(FieldPath.documentId, whereIn: batch)
            .get();

        for (final doc in snapshot.docs) {
          final data = doc.data() as Map<String, dynamic>? ?? {};
          names[doc.id] = data['name'] ?? 'Unknown Tenant';
        }
      }
    } catch (e) {
      if (kDebugMode) {
        print('⚠️ [TenantMessageHistory] Error loading tenant names: $e');
      }
    }

    return names;
  }
}
