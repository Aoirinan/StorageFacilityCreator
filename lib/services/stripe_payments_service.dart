import 'package:cloud_functions/cloud_functions.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';

/// Wraps Cloud Functions for embedded tenant payments (iframe-based Payment Element)
class StripePaymentsService {
  static final _functions = FirebaseFunctions.instance;

  /// Get publishable key from Cloud Function
  static Future<String?> getPublishableKey() async {
    try {
      final result = await _functions.httpsCallable('getStripePublishableKey').call();
      final data = result.data as Map<String, dynamic>?;
      return data?['publishableKey'] as String?;
    } catch (e) {
      if (kDebugMode) debugPrint('StripePaymentsService getPublishableKey: $e');
      return null;
    }
  }

  /// Get or create Stripe customer for tenant
  static Future<String> getOrCreateStripeCustomer({
    required String facilityId,
    required String tenantId,
  }) async {
    final result = await _functions.httpsCallable('getOrCreateStripeCustomer').call({
      'facilityId': facilityId,
      'tenantId': tenantId,
    });
    final data = result.data as Map<String, dynamic>;
    return data['stripeCustomerId'] as String;
  }

  /// Create SetupIntent for saving card.
  /// Returns clientSecret and optional publishableKey (use this key with the secret to avoid 401).
  static Future<({String clientSecret, String? publishableKey})> createEmbeddedSetupIntent({
    required String facilityId,
    required String tenantId,
  }) async {
    final result = await _functions.httpsCallable('createEmbeddedSetupIntent').call({
      'facilityId': facilityId,
      'tenantId': tenantId,
    });
    final data = result.data as Map<String, dynamic>;
    final clientSecret = data['clientSecret'] as String;
    final publishableKey = data['publishableKey'] as String?;
    return (clientSecret: clientSecret, publishableKey: publishableKey);
  }

  /// Create one-time PaymentIntent
  static Future<({String clientSecret, String paymentDocId})> createOneTimePaymentIntent({
    required String facilityId,
    required String tenantId,
    required int amountCents,
  }) async {
    final result = await _functions.httpsCallable('createOneTimePaymentIntent').call({
      'facilityId': facilityId,
      'tenantId': tenantId,
      'amountCents': amountCents,
    });
    final data = result.data as Map<String, dynamic>;
    return (
      clientSecret: data['clientSecret'] as String,
      paymentDocId: data['paymentDocId'] as String,
    );
  }

  /// Toggle AutoPay.
  ///
  /// Arms the nightly scheduled charge job against the tenant's stored card on
  /// the facility's connected Stripe account. No Stripe Subscription is created.
  static Future<bool> toggleAutopay({
    required String facilityId,
    required String tenantId,
    required bool enable,
  }) async {
    final result = await _functions.httpsCallable('toggleAutopay').call({
      'facilityId': facilityId,
      'tenantId': tenantId,
      'enable': enable,
    });
    final data = result.data as Map<String, dynamic>;
    return data['autopayEnabled'] as bool;
  }

  /// List saved payment methods
  static Future<List<Map<String, dynamic>>> listSavedPaymentMethods({
    required String facilityId,
    required String tenantId,
  }) async {
    final result = await _functions.httpsCallable('listSavedPaymentMethods').call({
      'facilityId': facilityId,
      'tenantId': tenantId,
    });
    final data = result.data as Map<String, dynamic>;
    final list = data['paymentMethods'] as List<dynamic>? ?? [];
    return list.map((e) => Map<String, dynamic>.from(e as Map)).toList();
  }

  /// Detach payment method
  static Future<void> detachPaymentMethod({
    required String facilityId,
    required String tenantId,
    required String paymentMethodId,
  }) async {
    await _functions.httpsCallable('detachPaymentMethod').call({
      'facilityId': facilityId,
      'tenantId': tenantId,
      'paymentMethodId': paymentMethodId,
    });
  }

  /// Stream tenant billing doc
  static Stream<DocumentSnapshot<Map<String, dynamic>>> watchTenantBilling({
    required String facilityId,
    required String tenantId,
  }) {
    return FirebaseFirestore.instance
        .collection('facilities')
        .doc(facilityId)
        .collection('tenants')
        .doc(tenantId)
        .collection('billing')
        .doc('default')
        .snapshots();
  }

  /// Stream tenant Stripe payments
  static Stream<QuerySnapshot<Map<String, dynamic>>> watchTenantPayments({
    required String facilityId,
    required String tenantId,
  }) {
    return FirebaseFirestore.instance
        .collection('facilities')
        .doc(facilityId)
        .collection('tenants')
        .doc(tenantId)
        .collection('payments')
        .orderBy('createdAt', descending: true)
        .limit(50)
        .snapshots();
  }
}
