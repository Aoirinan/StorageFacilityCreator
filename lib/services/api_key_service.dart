import 'dart:convert';
import 'dart:math';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:crypto/crypto.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:sfcapp/models/api_key_model.dart';

/// Service for managing API keys
class ApiKeyService {
  static final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  static final FirebaseAuth _auth = FirebaseAuth.instance;
  static final _random = Random.secure();

  /// Generate a new API key
  static String _generateApiKey() {
    // Generate a secure random API key
    final chars = 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';
    final keyParts = List.generate(2, (_) {
      return List.generate(32, (_) => chars[_random.nextInt(chars.length)]).join();
    });
    return 'sk_${keyParts.join()}';
  }

  /// Hash an API key for storage
  static String _hashApiKey(String key) {
    final bytes = utf8.encode(key);
    final digest = sha256.convert(bytes);
    return digest.toString();
  }

  /// Create a new API key
  /// Returns the plain-text key (only shown once)
  static Future<String> createApiKey({
    required String facilityId,
    required String name,
    String? description,
    List<String> permissions = const ['*'],
    DateTime? expiresAt,
    int? rateLimit,
    Map<String, dynamic>? metadata,
  }) async {
    try {
      final user = _auth.currentUser;
      if (user == null) throw Exception('User not authenticated');

      // Generate new key
      final plainKey = _generateApiKey();
      final keyHash = _hashApiKey(plainKey);

      final apiKey = ApiKey(
        id: '',
        facilityId: facilityId,
        name: name,
        keyHash: keyHash,
        description: description,
        permissions: permissions,
        createdAt: DateTime.now(),
        expiresAt: expiresAt,
        rateLimit: rateLimit,
        metadata: metadata,
      );

      await _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('apiKeys')
          .add(apiKey.toMap());

      if (kDebugMode) {
        print('✅ [ApiKey] Created API key: $name');
      }

      // Return plain key (only time it's available)
      return plainKey;
    } catch (e) {
      if (kDebugMode) {
        print('❌ [ApiKey] Error creating API key: $e');
      }
      rethrow;
    }
  }

  /// Get API keys for a facility
  static Future<List<ApiKey>> getApiKeys(String facilityId) async {
    try {
      final snapshot = await _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('apiKeys')
          .orderBy('createdAt', descending: true)
          .get();

      return snapshot.docs
          .map((doc) => ApiKey.fromMap(doc.id, doc.data()))
          .toList();
    } catch (e) {
      if (kDebugMode) {
        print('❌ [ApiKey] Error getting API keys: $e');
      }
      return [];
    }
  }

  /// Verify an API key and return the API key record if valid
  static Future<ApiKey?> verifyApiKey(String apiKey) async {
    try {
      final keyHash = _hashApiKey(apiKey);

      // Search across all facilities (collection group query)
      final snapshot = await _firestore
          .collectionGroup('apiKeys')
          .where('keyHash', isEqualTo: keyHash)
          .where('isActive', isEqualTo: true)
          .limit(1)
          .get();

      if (snapshot.docs.isEmpty) return null;

      final doc = snapshot.docs.first;
      final apiKeyRecord = ApiKey.fromMap(doc.id, doc.data());

      if (!apiKeyRecord.isValid) return null;

      // Update last used timestamp
      await doc.reference.update({
        'lastUsedAt': FieldValue.serverTimestamp(),
      });

      return apiKeyRecord;
    } catch (e) {
      if (kDebugMode) {
        print('❌ [ApiKey] Error verifying API key: $e');
      }
      return null;
    }
  }

  /// Revoke (deactivate) an API key
  static Future<void> revokeApiKey({
    required String facilityId,
    required String keyId,
  }) async {
    try {
      await _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('apiKeys')
          .doc(keyId)
          .update({'isActive': false});

      if (kDebugMode) {
        print('✅ [ApiKey] Revoked API key: $keyId');
      }
    } catch (e) {
      if (kDebugMode) {
        print('❌ [ApiKey] Error revoking API key: $e');
      }
      rethrow;
    }
  }

  /// Delete an API key permanently
  static Future<void> deleteApiKey({
    required String facilityId,
    required String keyId,
  }) async {
    try {
      await _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('apiKeys')
          .doc(keyId)
          .delete();

      if (kDebugMode) {
        print('✅ [ApiKey] Deleted API key: $keyId');
      }
    } catch (e) {
      if (kDebugMode) {
        print('❌ [ApiKey] Error deleting API key: $e');
      }
      rethrow;
    }
  }
}

