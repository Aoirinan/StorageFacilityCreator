import 'dart:convert';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:crypto/crypto.dart';
import '../models/webhook_model.dart';

/// Service for managing webhook subscriptions and deliveries
class WebhookService {
  static final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  static final FirebaseAuth _auth = FirebaseAuth.instance;

  /// Create a webhook subscription
  static Future<String> createWebhookSubscription({
    required String facilityId,
    required String url,
    String? description,
    required List<WebhookEventType> events,
    String? secret,
    Map<String, dynamic>? headers,
  }) async {
    try {
      final user = _auth.currentUser;
      if (user == null) throw Exception('User not authenticated');

      final subscription = WebhookSubscription(
        id: '',
        facilityId: facilityId,
        url: url,
        description: description,
        events: events,
        secret: secret,
        headers: headers,
        createdAt: DateTime.now(),
      );

      final docRef = await _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('webhookSubscriptions')
          .add(subscription.toMap());

      if (kDebugMode) {
        print('✅ [Webhook] Created webhook subscription: ${docRef.id}');
      }

      return docRef.id;
    } catch (e) {
      if (kDebugMode) {
        print('❌ [Webhook] Error creating webhook subscription: $e');
      }
      rethrow;
    }
  }

  /// Update a webhook subscription
  static Future<void> updateWebhookSubscription({
    required String facilityId,
    required String subscriptionId,
    String? url,
    String? description,
    List<WebhookEventType>? events,
    String? secret,
    Map<String, dynamic>? headers,
  }) async {
    try {
      final user = _auth.currentUser;
      if (user == null) throw Exception('User not authenticated');

      final updates = <String, dynamic>{
        'updatedAt': FieldValue.serverTimestamp(),
      };

      if (url != null) updates['url'] = url;
      if (description != null) updates['description'] = description;
      if (events != null) updates['events'] = events.map((e) => e.name).toList();
      if (secret != null) updates['secret'] = secret;
      if (headers != null) updates['headers'] = headers;

      await _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('webhookSubscriptions')
          .doc(subscriptionId)
          .update(updates);

      if (kDebugMode) {
        print('✅ [Webhook] Updated webhook subscription: $subscriptionId');
      }
    } catch (e) {
      if (kDebugMode) {
        print('❌ [Webhook] Error updating webhook subscription: $e');
      }
      rethrow;
    }
  }

  /// Get webhook subscriptions for a facility
  static Future<List<WebhookSubscription>> getWebhookSubscriptions(String facilityId) async {
    try {
      final snapshot = await _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('webhookSubscriptions')
          .where('isActive', isEqualTo: true)
          .orderBy('createdAt', descending: true)
          .get();

      return snapshot.docs
          .map((doc) => WebhookSubscription.fromMap(doc.id, doc.data()))
          .toList();
    } catch (e) {
      if (kDebugMode) {
        print('❌ [Webhook] Error getting webhook subscriptions: $e');
      }
      return [];
    }
  }

  /// Trigger webhooks for an event
  static Future<void> triggerWebhooks({
    required String facilityId,
    required WebhookEventType eventType,
    required Map<String, dynamic> payload,
  }) async {
    try {
      final subscriptions = await getWebhookSubscriptions(facilityId);
      final relevantSubscriptions = subscriptions
          .where((s) => s.subscribesTo(eventType))
          .toList();

      if (relevantSubscriptions.isEmpty) return;

      for (final subscription in relevantSubscriptions) {
        _deliverWebhook(subscription, eventType, payload);
      }
    } catch (e) {
      if (kDebugMode) {
        print('❌ [Webhook] Error triggering webhooks: $e');
      }
    }
  }

  /// Deliver a webhook to a subscription
  static Future<void> _deliverWebhook(
    WebhookSubscription subscription,
    WebhookEventType eventType,
    Map<String, dynamic> payload,
  ) async {
    try {
      // Prepare headers
      final headers = <String, String>{
        'Content-Type': 'application/json',
        'User-Agent': 'StorageFacilityCreator/1.0',
        ...?subscription.headers,
      };

      // Add signature if secret is provided
      final bodyJson = jsonEncode(payload);
      if (subscription.secret != null && subscription.secret!.isNotEmpty) {
        final hmac = Hmac(sha256, utf8.encode(subscription.secret!));
        final digest = hmac.convert(utf8.encode(bodyJson));
        headers['X-Webhook-Signature'] = 'sha256=$digest';
      }

      // Send webhook
      final response = await http.post(
        Uri.parse(subscription.url),
        headers: headers,
        body: bodyJson,
      ).timeout(const Duration(seconds: 30));

      // Record delivery
      final delivery = WebhookDelivery(
        id: '',
        subscriptionId: subscription.id,
        eventType: eventType,
        url: subscription.url,
        payload: payload,
        statusCode: response.statusCode,
        responseBody: response.body.isNotEmpty ? response.body : null,
        attemptedAt: DateTime.now(),
        success: response.statusCode >= 200 && response.statusCode < 300,
        errorMessage: response.statusCode >= 300 ? 'HTTP ${response.statusCode}' : null,
      );

      await _firestore
          .collection('facilities')
          .doc(subscription.facilityId)
          .collection('webhookSubscriptions')
          .doc(subscription.id)
          .collection('deliveries')
          .add(delivery.toMap());

      // Update subscription
      if (delivery.success) {
        await _firestore
            .collection('facilities')
            .doc(subscription.facilityId)
            .collection('webhookSubscriptions')
            .doc(subscription.id)
            .update({
          'lastTriggeredAt': FieldValue.serverTimestamp(),
          'failureCount': 0,
        });
      } else {
        await _firestore
            .collection('facilities')
            .doc(subscription.facilityId)
            .collection('webhookSubscriptions')
            .doc(subscription.id)
            .update({
          'failureCount': FieldValue.increment(1),
          'lastFailureAt': FieldValue.serverTimestamp(),
        });
      }

      if (kDebugMode) {
        print('✅ [Webhook] Delivered webhook to ${subscription.url}: ${response.statusCode}');
      }
    } catch (e) {
      if (kDebugMode) {
        print('❌ [Webhook] Error delivering webhook: $e');
      }

      // Record failed delivery
      try {
        final delivery = WebhookDelivery(
          id: '',
          subscriptionId: subscription.id,
          eventType: eventType,
          url: subscription.url,
          payload: payload,
          statusCode: 0,
          attemptedAt: DateTime.now(),
          success: false,
          errorMessage: e.toString(),
        );

        await _firestore
            .collection('facilities')
            .doc(subscription.facilityId)
            .collection('webhookSubscriptions')
            .doc(subscription.id)
            .collection('deliveries')
            .add(delivery.toMap());

        await _firestore
            .collection('facilities')
            .doc(subscription.facilityId)
            .collection('webhookSubscriptions')
            .doc(subscription.id)
            .update({
          'failureCount': FieldValue.increment(1),
          'lastFailureAt': FieldValue.serverTimestamp(),
        });
      } catch (recordError) {
        if (kDebugMode) {
          print('❌ [Webhook] Error recording failed delivery: $recordError');
        }
      }
    }
  }

  /// Delete a webhook subscription
  static Future<void> deleteWebhookSubscription({
    required String facilityId,
    required String subscriptionId,
  }) async {
    try {
      await _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('webhookSubscriptions')
          .doc(subscriptionId)
          .update({'isActive': false});

      if (kDebugMode) {
        print('✅ [Webhook] Deleted webhook subscription: $subscriptionId');
      }
    } catch (e) {
      if (kDebugMode) {
        print('❌ [Webhook] Error deleting webhook subscription: $e');
      }
      rethrow;
    }
  }

  /// Get webhook delivery history
  static Future<List<WebhookDelivery>> getWebhookDeliveries({
    required String facilityId,
    required String subscriptionId,
    int limit = 50,
  }) async {
    try {
      final snapshot = await _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('webhookSubscriptions')
          .doc(subscriptionId)
          .collection('deliveries')
          .orderBy('attemptedAt', descending: true)
          .limit(limit)
          .get();

      return snapshot.docs
          .map((doc) => WebhookDelivery.fromMap(doc.id, doc.data()))
          .toList();
    } catch (e) {
      if (kDebugMode) {
        print('❌ [Webhook] Error getting webhook deliveries: $e');
      }
      return [];
    }
  }
}

