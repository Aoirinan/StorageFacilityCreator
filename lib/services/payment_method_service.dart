import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import '../models/payment_method_model.dart';
import 'audit_service.dart';

/// Service for managing tenant payment methods
class PaymentMethodService {
  static final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  static final FirebaseAuth _auth = FirebaseAuth.instance;

  /// Create a payment method
  static Future<PaymentMethod> createPaymentMethod({
    required String tenantId,
    required String facilityId,
    required PaymentMethodType type,
    String? stripePaymentMethodId,
    String? stripeCustomerId,
    String? last4,
    String? brand,
    String? bankName,
    String? accountType,
    DateTime? expiryMonth,
    DateTime? expiryYear,
    bool setAsDefault = false,
  }) async {
    try {
      final user = _auth.currentUser;
      if (user == null) throw Exception('User not authenticated');

      if (kDebugMode) {
        print('🔄 [PaymentMethod] Creating payment method for tenant: $tenantId');
      }

      // If setting as default, unset other defaults
      if (setAsDefault) {
        await _unsetOtherDefaults(tenantId, facilityId);
      }

      final now = DateTime.now();
      final method = PaymentMethod(
        id: '', // Will be set by Firestore
        tenantId: tenantId,
        facilityId: facilityId,
        type: type,
        stripePaymentMethodId: stripePaymentMethodId,
        stripeCustomerId: stripeCustomerId,
        last4: last4,
        brand: brand,
        bankName: bankName,
        accountType: accountType,
        expiryMonth: expiryMonth,
        expiryYear: expiryYear,
        isDefault: setAsDefault,
        createdAt: now,
        createdBy: user.uid,
      );

      final ref = _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('tenants')
          .doc(tenantId)
          .collection('paymentMethods')
          .doc();

      await ref.set(method.copyWith(id: ref.id).toFirestore());

      final createdMethod = method.copyWith(id: ref.id);

      // Audit log
      await AuditService.logPaymentMethodCreated(
        facilityId: facilityId,
        tenantId: tenantId,
        methodId: ref.id,
        type: type.name,
      );

      if (kDebugMode) {
        print('✅ [PaymentMethod] Created payment method: ${ref.id}');
      }

      return createdMethod;
    } catch (e) {
      if (kDebugMode) {
        print('❌ [PaymentMethod] Error creating payment method: $e');
      }
      rethrow;
    }
  }

  /// Get payment methods for a tenant (real-time stream)
  static Stream<List<PaymentMethod>> getPaymentMethodsStream({
    required String tenantId,
    required String facilityId,
  }) {
    try {
      final user = _auth.currentUser;
      if (user == null) {
        throw Exception('Not signed in');
      }

      if (kDebugMode) {
        print('🔄 [PaymentMethod] Setting up payment methods stream for tenant: $tenantId');
      }

      return _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('tenants')
          .doc(tenantId)
          .collection('paymentMethods')
          .where('isActive', isEqualTo: true)
          .snapshots()
          .map((snapshot) {
        final methods = snapshot.docs
            .map((doc) => PaymentMethod.fromFirestore(doc))
            .toList();

        // Sort: default first, then by creation date
        methods.sort((a, b) {
          if (a.isDefault && !b.isDefault) return -1;
          if (!a.isDefault && b.isDefault) return 1;
          return b.createdAt.compareTo(a.createdAt);
        });

        if (kDebugMode) {
          print('📡 [PaymentMethod] Stream update: ${methods.length} methods for tenant: $tenantId');
        }

        return methods;
      });
    } catch (e) {
      if (kDebugMode) {
        print('❌ [PaymentMethod] Error setting up payment methods stream: $e');
      }
      rethrow;
    }
  }

  /// Get payment methods for a tenant (one-time)
  static Future<List<PaymentMethod>> getPaymentMethods({
    required String tenantId,
    required String facilityId,
  }) async {
    try {
      final user = _auth.currentUser;
      if (user == null) throw Exception('User not authenticated');

      if (kDebugMode) {
        print('🔄 [PaymentMethod] Getting payment methods for tenant: $tenantId');
      }

      final snapshot = await _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('tenants')
          .doc(tenantId)
          .collection('paymentMethods')
          .where('isActive', isEqualTo: true)
          .get();

      final methods = snapshot.docs
          .map((doc) => PaymentMethod.fromFirestore(doc))
          .toList();

      // Sort: default first, then by creation date
      methods.sort((a, b) {
        if (a.isDefault && !b.isDefault) return -1;
        if (!a.isDefault && b.isDefault) return 1;
        return b.createdAt.compareTo(a.createdAt);
      });

      if (kDebugMode) {
        print('✅ [PaymentMethod] Found ${methods.length} payment methods for tenant: $tenantId');
      }

      return methods;
    } catch (e) {
      if (kDebugMode) {
        print('❌ [PaymentMethod] Error getting payment methods: $e');
      }
      rethrow;
    }
  }

  /// Get default payment method for a tenant
  static Future<PaymentMethod?> getDefaultPaymentMethod({
    required String tenantId,
    required String facilityId,
  }) async {
    try {
      final methods = await getPaymentMethods(
        tenantId: tenantId,
        facilityId: facilityId,
      );

      return methods.firstWhere(
        (method) => method.isDefault,
        orElse: () => methods.isNotEmpty ? methods.first : throw StateError('No payment methods'),
      );
    } catch (e) {
      return null;
    }
  }

  /// Update payment method
  static Future<void> updatePaymentMethod({
    required String tenantId,
    required String facilityId,
    required String methodId,
    bool? isDefault,
    bool? autopayEnabled,
    AutopaySchedule? autopaySchedule,
    DateTime? autopayNextRun,
  }) async {
    try {
      final user = _auth.currentUser;
      if (user == null) throw Exception('User not authenticated');

      if (kDebugMode) {
        print('🔄 [PaymentMethod] Updating payment method: $methodId');
      }

      final updateData = <String, dynamic>{
        'updatedAt': FieldValue.serverTimestamp(),
      };

      if (isDefault != null) {
        updateData['isDefault'] = isDefault;
        if (isDefault) {
          // Unset other defaults
          await _unsetOtherDefaults(tenantId, facilityId, excludeId: methodId);
        }
      }

      if (autopayEnabled != null) {
        updateData['autopayEnabled'] = autopayEnabled;
      }

      if (autopaySchedule != null) {
        updateData['autopaySchedule'] = autopaySchedule.toMap();
      }

      if (autopayNextRun != null) {
        updateData['autopayNextRun'] = Timestamp.fromDate(autopayNextRun);
      }

      await _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('tenants')
          .doc(tenantId)
          .collection('paymentMethods')
          .doc(methodId)
          .update(updateData);

      // Audit log
      if (autopayEnabled != null) {
        await AuditService.logAutopayToggled(
          facilityId: facilityId,
          tenantId: tenantId,
          methodId: methodId,
          enabled: autopayEnabled,
        );
      }

      if (kDebugMode) {
        print('✅ [PaymentMethod] Updated payment method: $methodId');
      }
    } catch (e) {
      if (kDebugMode) {
        print('❌ [PaymentMethod] Error updating payment method: $e');
      }
      rethrow;
    }
  }

  /// Delete (deactivate) a payment method
  static Future<void> deletePaymentMethod({
    required String tenantId,
    required String facilityId,
    required String methodId,
  }) async {
    try {
      final user = _auth.currentUser;
      if (user == null) throw Exception('User not authenticated');

      if (kDebugMode) {
        print('🔄 [PaymentMethod] Deleting payment method: $methodId');
      }

      // Soft delete by setting isActive to false
      await _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('tenants')
          .doc(tenantId)
          .collection('paymentMethods')
          .doc(methodId)
          .update({
        'isActive': false,
        'updatedAt': FieldValue.serverTimestamp(),
      });

      // Audit log
      await AuditService.logPaymentMethodDeleted(
        facilityId: facilityId,
        tenantId: tenantId,
        methodId: methodId,
      );

      if (kDebugMode) {
        print('✅ [PaymentMethod] Deleted payment method: $methodId');
      }
    } catch (e) {
      if (kDebugMode) {
        print('❌ [PaymentMethod] Error deleting payment method: $e');
      }
      rethrow;
    }
  }

  /// Unset default flag for all other payment methods
  static Future<void> _unsetOtherDefaults(
    String tenantId,
    String facilityId, {
    String? excludeId,
  }) async {
    try {
      final query = _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('tenants')
          .doc(tenantId)
          .collection('paymentMethods')
          .where('isDefault', isEqualTo: true)
          .where('isActive', isEqualTo: true);

      final snapshot = await query.get();

      final batch = _firestore.batch();
      for (final doc in snapshot.docs) {
        if (doc.id != excludeId) {
          batch.update(doc.reference, {
            'isDefault': false,
            'updatedAt': FieldValue.serverTimestamp(),
          });
        }
      }

      if (snapshot.docs.isNotEmpty) {
        await batch.commit();
      }
    } catch (e) {
      if (kDebugMode) {
        print('⚠️ [PaymentMethod] Error unsetting defaults: $e');
      }
      // Don't throw - this is a helper function
    }
  }

  /// Get all payment methods with autopay enabled (for background job)
  static Future<List<PaymentMethod>> getAutopayMethods({
    required String facilityId,
    DateTime? beforeDate,
  }) async {
    try {
      if (kDebugMode) {
        print('🔄 [PaymentMethod] Getting autopay methods for facility: $facilityId');
      }

      Query query = _firestore
          .collectionGroup('paymentMethods')
          .where('facilityId', isEqualTo: facilityId)
          .where('isActive', isEqualTo: true)
          .where('autopayEnabled', isEqualTo: true);

      if (beforeDate != null) {
        query = query.where('autopayNextRun', isLessThanOrEqualTo: Timestamp.fromDate(beforeDate));
      }

      final snapshot = await query.get();

      final methods = snapshot.docs
          .map((doc) => PaymentMethod.fromFirestore(doc))
          .toList();

      if (kDebugMode) {
        print('✅ [PaymentMethod] Found ${methods.length} autopay methods');
      }

      return methods;
    } catch (e) {
      if (kDebugMode) {
        print('❌ [PaymentMethod] Error getting autopay methods: $e');
      }
      rethrow;
    }
  }

  /// Update autopay run result
  static Future<void> updateAutopayResult({
    required String tenantId,
    required String facilityId,
    required String methodId,
    required String result, // success, failed, skipped
    String? error,
    DateTime? nextRun,
  }) async {
    try {
      final updateData = <String, dynamic>{
        'autopayLastRun': FieldValue.serverTimestamp(),
        'autopayLastResult': result,
        'updatedAt': FieldValue.serverTimestamp(),
      };

      if (error != null) {
        updateData['autopayLastError'] = error;
      }

      if (nextRun != null) {
        updateData['autopayNextRun'] = Timestamp.fromDate(nextRun);
      }

      await _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('tenants')
          .doc(tenantId)
          .collection('paymentMethods')
          .doc(methodId)
          .update(updateData);

      if (kDebugMode) {
        print('✅ [PaymentMethod] Updated autopay result: $methodId');
      }
    } catch (e) {
      if (kDebugMode) {
        print('❌ [PaymentMethod] Error updating autopay result: $e');
      }
      rethrow;
    }
  }
}

