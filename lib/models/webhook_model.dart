import 'package:cloud_firestore/cloud_firestore.dart';

/// Webhook event types
enum WebhookEventType {
  tenantCreated,
  tenantUpdated,
  tenantDeleted,
  unitOccupied,
  unitVacated,
  paymentReceived,
  paymentFailed,
  contractSigned,
  contractExpired,
  reminderSent,
  all, // Subscribe to all events
}

/// Webhook subscription
class WebhookSubscription {
  final String id;
  final String facilityId;
  final String url; // Webhook endpoint URL
  final String? description;
  final List<WebhookEventType> events; // Events to subscribe to
  final String? secret; // Optional secret for signature verification
  final bool isActive;
  final DateTime createdAt;
  final DateTime? lastTriggeredAt;
  final int failureCount; // Number of consecutive failures
  final DateTime? lastFailureAt;
  final Map<String, dynamic>? headers; // Custom headers to include

  const WebhookSubscription({
    required this.id,
    required this.facilityId,
    required this.url,
    this.description,
    required this.events,
    this.secret,
    this.isActive = true,
    required this.createdAt,
    this.lastTriggeredAt,
    this.failureCount = 0,
    this.lastFailureAt,
    this.headers,
  });

  Map<String, dynamic> toMap() {
    return {
      'facilityId': facilityId,
      'url': url,
      'description': description,
      'events': events.map((e) => e.name).toList(),
      'secret': secret,
      'isActive': isActive,
      'createdAt': Timestamp.fromDate(createdAt),
      'lastTriggeredAt': lastTriggeredAt != null ? Timestamp.fromDate(lastTriggeredAt!) : null,
      'failureCount': failureCount,
      'lastFailureAt': lastFailureAt != null ? Timestamp.fromDate(lastFailureAt!) : null,
      'headers': headers,
    };
  }

  factory WebhookSubscription.fromMap(String id, Map<String, dynamic> map) {
    return WebhookSubscription(
      id: id,
      facilityId: map['facilityId'] as String,
      url: map['url'] as String,
      description: map['description'] as String?,
      events: (map['events'] as List<dynamic>?)
              ?.map((e) => WebhookEventType.values.firstWhere(
                    (et) => et.name == e,
                    orElse: () => WebhookEventType.all,
                  ))
              .toList() ??
          [],
      secret: map['secret'] as String?,
      isActive: map['isActive'] as bool? ?? true,
      createdAt: (map['createdAt'] as Timestamp).toDate(),
      lastTriggeredAt: (map['lastTriggeredAt'] as Timestamp?)?.toDate(),
      failureCount: map['failureCount'] as int? ?? 0,
      lastFailureAt: (map['lastFailureAt'] as Timestamp?)?.toDate(),
      headers: map['headers'] as Map<String, dynamic>?,
    );
  }

  bool subscribesTo(WebhookEventType event) {
    return events.contains(event) || events.contains(WebhookEventType.all);
  }
}

/// Webhook delivery record
class WebhookDelivery {
  final String id;
  final String subscriptionId;
  final WebhookEventType eventType;
  final String url;
  final Map<String, dynamic> payload;
  final int statusCode;
  final String? responseBody;
  final DateTime attemptedAt;
  final bool success;
  final String? errorMessage;

  const WebhookDelivery({
    required this.id,
    required this.subscriptionId,
    required this.eventType,
    required this.url,
    required this.payload,
    required this.statusCode,
    this.responseBody,
    required this.attemptedAt,
    required this.success,
    this.errorMessage,
  });

  Map<String, dynamic> toMap() {
    return {
      'subscriptionId': subscriptionId,
      'eventType': eventType.name,
      'url': url,
      'payload': payload,
      'statusCode': statusCode,
      'responseBody': responseBody,
      'attemptedAt': Timestamp.fromDate(attemptedAt),
      'success': success,
      'errorMessage': errorMessage,
    };
  }

  factory WebhookDelivery.fromMap(String id, Map<String, dynamic> map) {
    return WebhookDelivery(
      id: id,
      subscriptionId: map['subscriptionId'] as String,
      eventType: WebhookEventType.values.firstWhere(
        (e) => e.name == map['eventType'],
        orElse: () => WebhookEventType.all,
      ),
      url: map['url'] as String,
      payload: Map<String, dynamic>.from(map['payload']),
      statusCode: map['statusCode'] as int,
      responseBody: map['responseBody'] as String?,
      attemptedAt: (map['attemptedAt'] as Timestamp).toDate(),
      success: map['success'] as bool,
      errorMessage: map['errorMessage'] as String?,
    );
  }
}

