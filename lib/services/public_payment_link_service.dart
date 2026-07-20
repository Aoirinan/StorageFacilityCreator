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
    return '$base/pay?token=$token';
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
