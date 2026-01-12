import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import '../models/email_tracking_model.dart';

/// Service for email tracking
/// Currently provides basic tracking infrastructure
/// Full implementation requires SendGrid webhook integration
class EmailTrackingService {
  static final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  /// Log an email tracking event
  static Future<void> logEvent({
    required String messageId,
    required String facilityId,
    String? tenantId,
    required String to,
    required String subject,
    required String eventType,
    Map<String, dynamic>? metadata,
  }) async {
    try {
      await _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('emailTracking')
          .add({
        'messageId': messageId,
        'facilityId': facilityId,
        'tenantId': tenantId,
        'to': to,
        'subject': subject,
        'eventType': eventType,
        'timestamp': FieldValue.serverTimestamp(),
        'metadata': metadata,
      });

      if (kDebugMode) {
        print('✅ [EmailTracking] Logged event: $eventType for message $messageId');
      }
    } catch (e) {
      if (kDebugMode) {
        print('❌ [EmailTracking] Error logging event: $e');
      }
    }
  }

  /// Get tracking events for a message
  static Future<List<EmailTrackingEvent>> getEventsForMessage({
    required String facilityId,
    required String messageId,
  }) async {
    try {
      final snapshot = await _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('emailTracking')
          .where('messageId', isEqualTo: messageId)
          .orderBy('timestamp', descending: false)
          .get();

      return snapshot.docs
          .map((doc) => EmailTrackingEvent.fromMap(doc.id, doc.data()))
          .toList();
    } catch (e) {
      if (kDebugMode) {
        print('❌ [EmailTracking] Error getting events: $e');
      }
      return [];
    }
  }

  /// Get tracking statistics for a message
  static Future<EmailTrackingStats?> getStatsForMessage({
    required String facilityId,
    required String messageId,
  }) async {
    try {
      final events = await getEventsForMessage(
        facilityId: facilityId,
        messageId: messageId,
      );

      if (events.isEmpty) return null;

      return EmailTrackingStats.fromEvents(events);
    } catch (e) {
      if (kDebugMode) {
        print('❌ [EmailTracking] Error getting stats: $e');
      }
      return null;
    }
  }

  /// Get all tracking events for a facility
  static Stream<List<EmailTrackingEvent>> getEventsForFacility({
    required String facilityId,
    int? limit,
  }) {
    Query query = _firestore
        .collection('facilities')
        .doc(facilityId)
        .collection('emailTracking')
        .orderBy('timestamp', descending: true);

    if (limit != null) {
      query = query.limit(limit);
    }

    return query.snapshots().map((snapshot) {
      return snapshot.docs
          .map((doc) => EmailTrackingEvent.fromMap(doc.id, doc.data() as Map<String, dynamic>))
          .toList();
    });
  }

  /// Get tracking statistics summary for a facility
  static Future<Map<String, dynamic>> getFacilityStats({
    required String facilityId,
    DateTime? startDate,
    DateTime? endDate,
  }) async {
    try {
      Query query = _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('emailTracking')
          .orderBy('timestamp', descending: false);

      if (startDate != null) {
        query = query.where('timestamp', isGreaterThanOrEqualTo: Timestamp.fromDate(startDate));
      }

      final snapshot = await query.get();

      final events = snapshot.docs
          .map((doc) => EmailTrackingEvent.fromMap(doc.id, doc.data() as Map<String, dynamic>))
          .toList();

      // Filter by end date if provided
      final filteredEvents = endDate != null
          ? events.where((e) => e.timestamp.isBefore(endDate)).toList()
          : events;

      final totalSent = filteredEvents.where((e) => e.eventType == 'sent').length;
      final totalOpened = filteredEvents.where((e) => e.eventType == 'opened').length;
      final totalClicked = filteredEvents.where((e) => e.eventType == 'clicked').length;
      final totalBounced = filteredEvents.where((e) => e.eventType == 'bounced').length;
      final totalFailed = filteredEvents.where((e) => e.eventType == 'failed').length;

      final openRate = totalSent > 0 ? (totalOpened / totalSent) * 100 : 0.0;
      final clickRate = totalSent > 0 ? (totalClicked / totalSent) * 100 : 0.0;

      return {
        'totalSent': totalSent,
        'totalOpened': totalOpened,
        'totalClicked': totalClicked,
        'totalBounced': totalBounced,
        'totalFailed': totalFailed,
        'openRate': openRate,
        'clickRate': clickRate,
      };
    } catch (e) {
      if (kDebugMode) {
        print('❌ [EmailTracking] Error getting facility stats: $e');
      }
      return {};
    }
  }
}

/// Note: Full email tracking requires SendGrid webhook integration
/// 
/// To implement full tracking:
/// 1. Configure SendGrid webhook URL to point to Cloud Function
/// 2. Create Cloud Function to handle SendGrid webhook events
/// 3. Process events (delivered, open, click, bounce, etc.)
/// 4. Store events in Firestore using EmailTrackingService.logEvent()
/// 
/// SendGrid webhook events include:
/// - delivered: Email was successfully delivered
/// - open: Email was opened
/// - click: Link in email was clicked
/// - bounce: Email bounced
/// - dropped: Email was dropped
/// - spam_report: Recipient marked as spam
/// - unsubscribe: Recipient unsubscribed
/// 
/// Example Cloud Function:
/// ```typescript
/// export const handleSendGridWebhook = functions.https.onRequest(async (req, res) => {
///   const events = req.body;
///   for (const event of events) {
///     await admin.firestore()
///       .collection('facilities')
///       .doc(event.metadata?.facilityId)
///       .collection('emailTracking')
///       .add({
///         messageId: event.sg_message_id,
///         eventType: event.event,
///         to: event.email,
///         timestamp: admin.firestore.FieldValue.serverTimestamp(),
///         metadata: event,
///       });
///   }
///   res.status(200).send('OK');
/// });
/// ```

