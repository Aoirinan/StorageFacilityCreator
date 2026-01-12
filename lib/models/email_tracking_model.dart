import 'package:cloud_firestore/cloud_firestore.dart';

/// Model for email tracking events
class EmailTrackingEvent {
  final String id;
  final String messageId; // SendGrid message ID
  final String facilityId;
  final String? tenantId;
  final String to;
  final String subject;
  final String eventType; // sent, opened, clicked, bounced, failed
  final DateTime timestamp;
  final Map<String, dynamic>? metadata;

  EmailTrackingEvent({
    required this.id,
    required this.messageId,
    required this.facilityId,
    this.tenantId,
    required this.to,
    required this.subject,
    required this.eventType,
    required this.timestamp,
    this.metadata,
  });

  factory EmailTrackingEvent.fromMap(String id, Map<String, dynamic> map) {
    return EmailTrackingEvent(
      id: id,
      messageId: map['messageId'] ?? '',
      facilityId: map['facilityId'] ?? '',
      tenantId: map['tenantId'],
      to: map['to'] ?? '',
      subject: map['subject'] ?? '',
      eventType: map['eventType'] ?? 'sent',
      timestamp: (map['timestamp'] as Timestamp?)?.toDate() ?? DateTime.now(),
      metadata: map['metadata'] != null ? Map<String, dynamic>.from(map['metadata']) : null,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'messageId': messageId,
      'facilityId': facilityId,
      'tenantId': tenantId,
      'to': to,
      'subject': subject,
      'eventType': eventType,
      'timestamp': Timestamp.fromDate(timestamp),
      'metadata': metadata,
    };
  }
}

/// Email tracking statistics for a message
class EmailTrackingStats {
  final String messageId;
  final bool sent;
  final DateTime? sentAt;
  final bool opened;
  final DateTime? openedAt;
  final int openCount;
  final bool clicked;
  final DateTime? clickedAt;
  final int clickCount;
  final bool bounced;
  final bool failed;
  final DateTime? failedAt;

  const EmailTrackingStats({
    required this.messageId,
    this.sent = false,
    this.sentAt,
    this.opened = false,
    this.openedAt,
    this.openCount = 0,
    this.clicked = false,
    this.clickedAt,
    this.clickCount = 0,
    this.bounced = false,
    this.failed = false,
    this.failedAt,
  });

  factory EmailTrackingStats.fromEvents(List<EmailTrackingEvent> events) {
    if (events.isEmpty) {
      return const EmailTrackingStats(messageId: '');
    }

    final messageId = events.first.messageId;
    final sentEvent = events.firstWhere((e) => e.eventType == 'sent', orElse: () => events.first);
    final openedEvents = events.where((e) => e.eventType == 'opened').toList();
    final clickedEvents = events.where((e) => e.eventType == 'clicked').toList();
    final bouncedEvent = events.firstWhere((e) => e.eventType == 'bounced', orElse: () => sentEvent);
    final failedEvent = events.firstWhere((e) => e.eventType == 'failed', orElse: () => sentEvent);

    return EmailTrackingStats(
      messageId: messageId,
      sent: sentEvent.eventType == 'sent',
      sentAt: sentEvent.timestamp,
      opened: openedEvents.isNotEmpty,
      openedAt: openedEvents.isNotEmpty ? openedEvents.first.timestamp : null,
      openCount: openedEvents.length,
      clicked: clickedEvents.isNotEmpty,
      clickedAt: clickedEvents.isNotEmpty ? clickedEvents.first.timestamp : null,
      clickCount: clickedEvents.length,
      bounced: bouncedEvent.eventType == 'bounced',
      failed: failedEvent.eventType == 'failed',
      failedAt: failedEvent.eventType == 'failed' ? failedEvent.timestamp : null,
    );
  }
}

