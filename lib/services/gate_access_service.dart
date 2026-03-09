import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';

import '../models/gate_access_model.dart';
import 'audit_service.dart';

class GateAccessService {
  static final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  static final FirebaseAuth _auth = FirebaseAuth.instance;

  static Stream<List<GateAccessModel>> getGateAccessStream(String facilityId) {
    try {
      final user = _auth.currentUser;
      if (user == null) {
        throw Exception('Not signed in');
      }

      Query query = _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('gateAccess');

      try {
        query = query.orderBy('createdAt', descending: true);
      } catch (orderingError) {
        if (kDebugMode) {
          print('⚠️ Ordered query not available for gate access: $orderingError');
        }
      }

      return query.snapshots().map((snapshot) {
        final entries = snapshot.docs
            .map((doc) => GateAccessModel.fromFirestore(doc))
            .toList();
        entries.sort((a, b) => a.accessCode.compareTo(b.accessCode));
        return entries;
      });
    } catch (e) {
      if (kDebugMode) {
        print('❌ Error streaming gate access records: $e');
      }
      rethrow;
    }
  }

  static Future<GateAccessModel> createGateAccess({
    required String facilityId,
    required String accessCode,
    String? tenantId,
    String? tenantName,
    bool isActive = true,
    DateTime? validFrom,
    DateTime? validUntil,
    List<String> allowedDays = const [],
    String? allowedStartTime,
    String? allowedEndTime,
    String? notes,
  }) async {
    try {
      final user = _auth.currentUser;
      if (user == null) throw Exception('Not signed in');

      final ref = _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('gateAccess')
          .doc();

      final now = DateTime.now();
      final data = {
        'facilityId': facilityId,
        'tenantId': tenantId,
        'tenantName': tenantName,
        'accessCode': accessCode,
        'isActive': isActive,
        'validFrom': validFrom != null ? Timestamp.fromDate(validFrom) : null,
        'validUntil': validUntil != null ? Timestamp.fromDate(validUntil) : null,
        'allowedDays': allowedDays,
        'allowedStartTime': allowedStartTime,
        'allowedEndTime': allowedEndTime,
        'notes': notes,
        'createdAt': Timestamp.fromDate(now),
        'updatedAt': Timestamp.fromDate(now),
        'createdBy': user.uid,
      };

      await ref.set(data);

      if (kDebugMode) {
        print('✅ Gate access created: ${ref.id}');
      }

      return GateAccessModel(
        id: ref.id,
        facilityId: facilityId,
        tenantId: tenantId,
        tenantName: tenantName,
        accessCode: accessCode,
        isActive: isActive,
        validFrom: validFrom,
        validUntil: validUntil,
        allowedDays: allowedDays,
        allowedStartTime: allowedStartTime,
        allowedEndTime: allowedEndTime,
        notes: notes,
        createdAt: now,
        updatedAt: now,
        createdBy: user.uid,
        updatedBy: null,
      );
    } catch (e) {
      if (kDebugMode) {
        print('❌ Error creating gate access: $e');
      }
      rethrow;
    }
  }

  static Future<void> updateGateAccess({
    required String facilityId,
    required String accessId,
    String? tenantId,
    String? tenantName,
    String? accessCode,
    bool? isActive,
    DateTime? validFrom,
    DateTime? validUntil,
    List<String>? allowedDays,
    String? allowedStartTime,
    String? allowedEndTime,
    String? notes,
  }) async {
    try {
      final user = _auth.currentUser;
      if (user == null) throw Exception('Not signed in');

      final updates = <String, dynamic>{
        'updatedAt': Timestamp.fromDate(DateTime.now()),
        'updatedBy': user.uid,
      };

      if (tenantId != null) updates['tenantId'] = tenantId;
      if (tenantName != null) updates['tenantName'] = tenantName;
      if (accessCode != null) updates['accessCode'] = accessCode;
      if (isActive != null) updates['isActive'] = isActive;
      if (validFrom != null) updates['validFrom'] = Timestamp.fromDate(validFrom);
      if (validUntil != null) updates['validUntil'] = Timestamp.fromDate(validUntil);
      if (allowedDays != null) updates['allowedDays'] = allowedDays;
      if (allowedStartTime != null) updates['allowedStartTime'] = allowedStartTime;
      if (allowedEndTime != null) updates['allowedEndTime'] = allowedEndTime;
      if (notes != null) updates['notes'] = notes;

      await _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('gateAccess')
          .doc(accessId)
          .update(updates);

      if (kDebugMode) {
        print('✅ Gate access updated: $accessId');
      }
    } catch (e) {
      if (kDebugMode) {
        print('❌ Error updating gate access: $e');
      }
      rethrow;
    }
  }

  static Future<void> deleteGateAccess({
    required String facilityId,
    required String accessId,
  }) async {
    try {
      await _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('gateAccess')
          .doc(accessId)
          .delete();

      if (kDebugMode) {
        print('🗑️ Gate access deleted: $accessId');
      }
    } catch (e) {
      if (kDebugMode) {
        print('❌ Error deleting gate access: $e');
      }
      rethrow;
    }
  }

  /// Get active gate access code for a specific tenant
  static Future<String?> getGateAccessCodeForTenant({
    required String facilityId,
    required String tenantId,
  }) async {
    try {
      final snapshot = await _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('gateAccess')
          .where('tenantId', isEqualTo: tenantId)
          .where('isActive', isEqualTo: true)
          .limit(1)
          .get();

      if (snapshot.docs.isEmpty) {
        return null;
      }

      final entry = GateAccessModel.fromFirestore(snapshot.docs.first);
      return entry.accessCode;
    } catch (e) {
      if (kDebugMode) {
        print('❌ Error getting gate access code for tenant: $e');
      }
      return null;
    }
  }

  /// Get gate access model for a specific tenant (returns most recent active or inactive)
  static Future<GateAccessModel?> getGateAccessForTenant({
    required String facilityId,
    required String tenantId,
  }) async {
    try {
      // Query without orderBy to avoid requiring a composite index.
      // Sort client-side so the most recent record is returned.
      final snapshot = await _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('gateAccess')
          .where('tenantId', isEqualTo: tenantId)
          .get();

      if (snapshot.docs.isEmpty) {
        return null;
      }

      final records = snapshot.docs
          .map((doc) => GateAccessModel.fromFirestore(doc))
          .toList();

      // Prefer active records; within that, most recently created first.
      records.sort((a, b) {
        if (a.isActive != b.isActive) return a.isActive ? -1 : 1;
        return b.createdAt.compareTo(a.createdAt);
      });

      return records.first;
    } catch (e) {
      if (kDebugMode) {
        print('❌ Error getting gate access for tenant: $e');
      }
      return null;
    }
  }

  /// Generate a unique access code for a facility
  /// Ensures the code doesn't already exist in the facility
  static Future<String> generateUniqueAccessCode({
    required String facilityId,
    int length = 6,
    int maxAttempts = 100,
  }) async {
    for (int attempt = 0; attempt < maxAttempts; attempt++) {
      // Generate random code
      final random = DateTime.now().millisecondsSinceEpoch + attempt;
      final code = (random % 1000000).toString().padLeft(length, '0');
      
      // Check if code already exists
      final existing = await _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('gateAccess')
          .where('accessCode', isEqualTo: code)
          .where('isActive', isEqualTo: true)
          .limit(1)
          .get();

      if (existing.docs.isEmpty) {
        return code;
      }
    }

    // Fallback: use timestamp-based code if all attempts fail
    final fallbackCode = DateTime.now().millisecondsSinceEpoch.toString().substring(7);
    if (kDebugMode) {
      print('⚠️ [GateAccess] Using fallback code generation after $maxAttempts attempts');
    }
    return fallbackCode;
  }

  /// Bulk enable/disable gate access for multiple tenants
  static Future<Map<String, bool>> bulkUpdateGateAccess({
    required String facilityId,
    required List<String> tenantIds,
    required bool isActive,
    String? reason,
  }) async {
    final results = <String, bool>{};
    
    for (final tenantId in tenantIds) {
      try {
        final gateAccess = await getGateAccessForTenant(
          facilityId: facilityId,
          tenantId: tenantId,
        );

        if (gateAccess != null) {
          await updateGateAccess(
            facilityId: facilityId,
            accessId: gateAccess.id,
            isActive: isActive,
            notes: reason != null 
                ? '${gateAccess.notes ?? ''}\n${DateTime.now().toIso8601String()}: $reason'.trim()
                : gateAccess.notes,
          );
          results[tenantId] = true;
        } else {
          results[tenantId] = false;
        }
      } catch (e) {
        if (kDebugMode) {
          print('❌ Error updating gate access for tenant $tenantId: $e');
        }
        results[tenantId] = false;
      }
    }

    return results;
  }
}

