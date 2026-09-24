import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';

/// Service for creating and managing public payment links
/// Allows tenants to pay without logging into the portal
class PublicPaymentLinkService {
  static final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  static final FirebaseFunctions _functions = FirebaseFunctions.instance;
  static final FirebaseAuth _auth = FirebaseAuth.instance;

  /// Create a public payment link for a tenant
  /// Returns a secure token that can be used in a public URL
  static Future<String> createPaymentLink({
    required String facilityId,
    required String tenantId,
    required double amount,
    String? description,
    DateTime? expiresAt,
  }) async {
    try {
      final user = _auth.currentUser;
      if (user == null) throw Exception('Not signed in');

      // Calculate expiration (default 30 days)
      final expiration =
          expiresAt ?? DateTime.now().add(const Duration(days: 30));
      final callable = _functions.httpsCallable('createPublicPaymentLink');
      final result = await callable.call(<String, dynamic>{
        'facilityId': facilityId,
        'tenantId': tenantId,
        'amount': amount,
        'description': description ?? 'Payment',
        'expiresAt': expiration.toUtc().toIso8601String(),
      });
      final payload = Map<String, dynamic>.from(result.data as Map);
      final token = payload['token']?.toString() ?? '';
      if (token.isEmpty) {
        throw Exception('Payment link creation returned no token');
      }

      if (kDebugMode) {
        print('✅ [PublicPaymentLink] Created payment link: $token');
      }

      return token;
    } catch (e) {
      if (kDebugMode) {
        print('❌ [PublicPaymentLink] Error creating link: $e');
      }
      rethrow;
    }
  }

  /// Get payment link details by token
  static Future<PublicPaymentLink?> getPaymentLink(String token) async {
    try {
      final callable = _functions.httpsCallable('getPublicPaymentLink');
      final result =
          await callable.call(<String, dynamic>{'token': token.trim()});
      final payload = Map<String, dynamic>.from(result.data as Map);
      if (payload['found'] != true || payload['paymentLink'] is! Map) {
        return null;
      }
      final data = Map<String, dynamic>.from(payload['paymentLink'] as Map);
      return PublicPaymentLink.fromMap(token.trim(), data);
    } catch (e) {
      if (kDebugMode) {
        print('❌ [PublicPaymentLink] Error getting link: $e');
      }
      return null;
    }
  }

  /// Start (or resume) checkout for a link. The server hands back the link's
  /// open Stripe session rather than making another, and says so when the link
  /// has already been paid, so pressing Pay Now twice cannot charge twice.
  static Future<PublicCheckoutStart> startCheckout(String token) async {
    final callable = _functions.httpsCallable('createPublicPaymentCheckout');
    final result = await callable
        .call(<String, dynamic>{'token': token.trim()}).timeout(
      const Duration(seconds: 60),
      onTimeout: () => throw Exception('Request timed out. Please try again.'),
    );
    final data = Map<String, dynamic>.from(result.data as Map);
    if (data['alreadyPaid'] == true) return const PublicCheckoutStart.alreadyPaid();
    final url = data['checkoutUrl'];
    if (url is! String || url.isEmpty) {
      throw Exception('Failed to create checkout session');
    }
    return PublicCheckoutStart.checkout(url);
  }

  /// After Stripe sends the tenant back, apply the paid session to the link
  /// without waiting for the webhook. Returns 'paid', 'received' (paid, but
  /// the link could not take it; the facility has been told), 'processing' or
  /// 'unpaid'.
  static Future<String> confirmCheckout({
    required String token,
    required String sessionId,
  }) async {
    final callable = _functions.httpsCallable('confirmPublicPaymentCheckout');
    final result = await callable.call(<String, dynamic>{
      'token': token.trim(),
      'sessionId': sessionId.trim(),
    }).timeout(const Duration(seconds: 30));
    final data = Map<String, dynamic>.from(result.data as Map);
    return (data['status'] ?? 'processing').toString();
  }

  /// Get all payment links for a facility
  static Future<List<PublicPaymentLink>> getPaymentLinksForFacility({
    required String facilityId,
    String? status,
  }) async {
    try {
      final user = _auth.currentUser;
      if (user == null) throw Exception('Not signed in');

      Query query = _firestore
          .collection('publicPaymentLinks')
          .where('facilityId', isEqualTo: facilityId);

      if (status != null) {
        query = query.where('status', isEqualTo: status);
      }

      final snapshot = await query.orderBy('createdAt', descending: true).get();

      return snapshot.docs
          .map((doc) => PublicPaymentLink.fromMap(
              doc.id, doc.data() as Map<String, dynamic>))
          .toList();
    } catch (e) {
      if (kDebugMode) {
        print('❌ [PublicPaymentLink] Error getting links: $e');
      }
      rethrow;
    }
  }

  /// Revoke a payment link
  static Future<void> revokePaymentLink(String token) async {
    try {
      await _firestore.collection('publicPaymentLinks').doc(token).update({
        'status': 'revoked',
        'revokedAt': FieldValue.serverTimestamp(),
      });

      if (kDebugMode) {
        print('✅ [PublicPaymentLink] Revoked link: $token');
      }
    } catch (e) {
      if (kDebugMode) {
        print('❌ [PublicPaymentLink] Error revoking link: $e');
      }
      rethrow;
    }
  }

  /// Build public payment URL
  static String buildPaymentUrl(String token, {String? baseUrl}) {
    final base = baseUrl ?? 'https://app.storagefacilitycreator.com';
    // Hash route: the app routes by hash, and a path-style /pay?token=… lands
    // the tenant on the facility-manager login instead of the payment page.
    return '$base/#/pay?token=$token';
  }
}

/// What starting checkout produced: a Stripe URL, or word that the link is
/// already paid.
class PublicCheckoutStart {
  const PublicCheckoutStart.checkout(String this.checkoutUrl) : alreadyPaid = false;
  const PublicCheckoutStart.alreadyPaid()
      : checkoutUrl = null,
        alreadyPaid = true;

  final String? checkoutUrl;
  final bool alreadyPaid;
}

/// Stripe's return to the payment page: `?status=success&session_id=cs_…`
/// before the hash (`#/pay?token=…`). On web that is [Uri.base]; in the mobile
/// WebView it is the URL the checkout navigates to.
class PublicCheckoutReturn {
  const PublicCheckoutReturn({required this.status, this.sessionId});

  final String status;
  final String? sessionId;

  bool get isSuccess => status == 'success' && sessionId != null;

  static PublicCheckoutReturn? fromUri(Uri uri) {
    final params = uri.queryParameters;
    final status = params['status'];
    if (status == null || status.isEmpty) return null;
    final sessionId = params['session_id'];
    return PublicCheckoutReturn(
      status: status,
      // Only a real Checkout Session id; the literal template never is one.
      sessionId: sessionId != null && sessionId.startsWith('cs_') ? sessionId : null,
    );
  }
}

/// Model for public payment link
class PublicPaymentLink {
  final String id;
  final String facilityId;
  final String tenantId;
  final double amount;
  final String description;
  final String token;
  final String status; // pending, paid, revoked, expired
  final DateTime createdAt;
  final DateTime expiresAt;
  final String createdBy;
  final String? paymentIntentId;
  final DateTime? paidAt;
  final DateTime? revokedAt;

  PublicPaymentLink({
    required this.id,
    required this.facilityId,
    required this.tenantId,
    required this.amount,
    required this.description,
    required this.token,
    required this.status,
    required this.createdAt,
    required this.expiresAt,
    required this.createdBy,
    this.paymentIntentId,
    this.paidAt,
    this.revokedAt,
  });

  factory PublicPaymentLink.fromMap(String id, Map<String, dynamic> map) {
    DateTime? parseDate(dynamic value) {
      if (value is Timestamp) return value.toDate();
      if (value is String) return DateTime.tryParse(value);
      return null;
    }

    final amountValue = map['amount'];

    return PublicPaymentLink(
      id: id,
      facilityId: map['facilityId'] ?? '',
      tenantId: map['tenantId'] ?? '',
      amount: amountValue is num ? amountValue.toDouble() : 0,
      description: map['description'] ?? '',
      token: map['token'] ?? '',
      status: map['status'] ?? 'pending',
      createdAt: parseDate(map['createdAt']) ?? DateTime.now(),
      expiresAt: parseDate(map['expiresAt']) ?? DateTime.now(),
      createdBy: map['createdBy'] ?? '',
      paymentIntentId: map['paymentIntentId'],
      paidAt: parseDate(map['paidAt']),
      revokedAt: parseDate(map['revokedAt']),
    );
  }

  bool get isExpired => expiresAt.isBefore(DateTime.now());
  bool get isActive => status == 'pending' && !isExpired;
  String get paymentUrl => PublicPaymentLinkService.buildPaymentUrl(token);
}
