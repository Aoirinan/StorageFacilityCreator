import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:crypto/crypto.dart';
import 'dart:convert';

/// Service for creating and managing public payment links
/// Allows tenants to pay without logging into the portal
class PublicPaymentLinkService {
  static final FirebaseFirestore _firestore = FirebaseFirestore.instance;
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

      // Generate secure token
      final token = _generateSecureToken();

      // Calculate expiration (default 30 days)
      final expiration = expiresAt ?? DateTime.now().add(const Duration(days: 30));

      // Create payment link document
      final linkData = {
        'facilityId': facilityId,
        'tenantId': tenantId,
        'amount': amount,
        'description': description ?? 'Payment',
        'token': token,
        'status': 'pending',
        'createdAt': FieldValue.serverTimestamp(),
        'expiresAt': Timestamp.fromDate(expiration),
        'createdBy': user.uid,
        'paymentIntentId': null,
        'paidAt': null,
      };

      await _firestore.collection('publicPaymentLinks').doc(token).set(linkData);

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
      final doc = await _firestore.collection('publicPaymentLinks').doc(token).get();
      
      if (!doc.exists) {
        return null;
      }

      final data = doc.data()!;
      
      // Check if expired
      final expiresAt = (data['expiresAt'] as Timestamp?)?.toDate();
      if (expiresAt != null && expiresAt.isBefore(DateTime.now())) {
        return null;
      }

      return PublicPaymentLink.fromMap(doc.id, data);
    } catch (e) {
      if (kDebugMode) {
        print('❌ [PublicPaymentLink] Error getting link: $e');
      }
      return null;
    }
  }

  /// Mark payment link as paid
  static Future<void> markAsPaid({
    required String token,
    required String paymentIntentId,
  }) async {
    try {
      await _firestore.collection('publicPaymentLinks').doc(token).update({
        'status': 'paid',
        'paymentIntentId': paymentIntentId,
        'paidAt': FieldValue.serverTimestamp(),
      });

      if (kDebugMode) {
        print('✅ [PublicPaymentLink] Marked as paid: $token');
      }
    } catch (e) {
      if (kDebugMode) {
        print('❌ [PublicPaymentLink] Error marking as paid: $e');
      }
      rethrow;
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
          .map((doc) => PublicPaymentLink.fromMap(doc.id, doc.data() as Map<String, dynamic>))
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

  /// Generate secure random token
  static String _generateSecureToken() {
    final random = DateTime.now().millisecondsSinceEpoch.toString() + 
                   DateTime.now().microsecondsSinceEpoch.toString();
    final bytes = utf8.encode(random);
    final digest = sha256.convert(bytes);
    return digest.toString().substring(0, 32);
  }

  /// Build public payment URL
  static String buildPaymentUrl(String token, {String? baseUrl}) {
    final base = baseUrl ?? 'https://storage-facility-creator.web.app';
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
    return PublicPaymentLink(
      id: id,
      facilityId: map['facilityId'] ?? '',
      tenantId: map['tenantId'] ?? '',
      amount: (map['amount'] ?? 0.0).toDouble(),
      description: map['description'] ?? '',
      token: map['token'] ?? '',
      status: map['status'] ?? 'pending',
      createdAt: (map['createdAt'] as Timestamp?)?.toDate() ?? DateTime.now(),
      expiresAt: (map['expiresAt'] as Timestamp?)?.toDate() ?? DateTime.now(),
      createdBy: map['createdBy'] ?? '',
      paymentIntentId: map['paymentIntentId'],
      paidAt: (map['paidAt'] as Timestamp?)?.toDate(),
      revokedAt: (map['revokedAt'] as Timestamp?)?.toDate(),
    );
  }

  bool get isExpired => expiresAt.isBefore(DateTime.now());
  bool get isActive => status == 'pending' && !isExpired;
  String get paymentUrl => PublicPaymentLinkService.buildPaymentUrl(token);
}

