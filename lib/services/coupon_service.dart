import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:sfcapp/models/coupon_model.dart';

/// Service for managing coupons
class CouponService {
  static final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  static final FirebaseAuth _auth = FirebaseAuth.instance;

  /// Get coupon by code
  static Future<CouponModel?> getCouponByCode({
    required String facilityId,
    required String code,
  }) async {
    try {
      final user = _auth.currentUser;
      if (user == null) throw Exception('User not authenticated');

      final snapshot = await _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('coupons')
          .where('code', isEqualTo: code.toUpperCase())
          .where('isActive', isEqualTo: true)
          .limit(1)
          .get();

      if (snapshot.docs.isEmpty) return null;

      return CouponModel.fromFirestore(snapshot.docs.first);
    } catch (e) {
      if (kDebugMode) {
        print('❌ [Coupon] Error getting coupon by code: $e');
      }
      rethrow;
    }
  }

  /// Get all coupons for a facility
  static Future<List<CouponModel>> getCouponsForFacility(String facilityId) async {
    try {
      final user = _auth.currentUser;
      if (user == null) throw Exception('User not authenticated');

      final snapshot = await _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('coupons')
          .orderBy('createdAt', descending: true)
          .get();

      return snapshot.docs
          .map((doc) => CouponModel.fromFirestore(doc))
          .toList();
    } catch (e) {
      if (kDebugMode) {
        print('❌ [Coupon] Error getting coupons: $e');
      }
      rethrow;
    }
  }

  /// Get stream of coupons for a facility
  static Stream<List<CouponModel>> getCouponsForFacilityStream(String facilityId) {
    try {
      final user = _auth.currentUser;
      if (user == null) throw Exception('User not authenticated');

      return _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('coupons')
          .orderBy('createdAt', descending: true)
          .snapshots()
          .map((snapshot) => snapshot.docs
              .map((doc) => CouponModel.fromFirestore(doc))
              .toList());
    } catch (e) {
      if (kDebugMode) {
        print('❌ [Coupon] Error getting coupons stream: $e');
      }
      rethrow;
    }
  }

  /// Create a new coupon
  static Future<CouponModel> createCoupon({
    required String facilityId,
    required String code,
    required String name,
    String? description,
    required CouponType type,
    required double value,
    DateTime? validFrom,
    DateTime? validUntil,
    int? maxUses,
    double? minPurchaseAmount,
    bool appliesToRent = true,
    bool appliesToFees = true,
    bool appliesToInsurance = false,
  }) async {
    try {
      final user = _auth.currentUser;
      if (user == null) throw Exception('User not authenticated');

      // Check if code already exists
      final existing = await getCouponByCode(
        facilityId: facilityId,
        code: code,
      );
      if (existing != null) {
        throw Exception('Coupon code already exists');
      }

      final coupon = CouponModel(
        id: '', // Will be set by Firestore
        facilityId: facilityId,
        code: code.toUpperCase(),
        name: name,
        description: description,
        type: type,
        value: value,
        status: CouponStatus.active,
        validFrom: validFrom,
        validUntil: validUntil,
        maxUses: maxUses,
        currentUses: 0,
        minPurchaseAmount: minPurchaseAmount,
        appliesToRent: appliesToRent,
        appliesToFees: appliesToFees,
        appliesToInsurance: appliesToInsurance,
        createdAt: DateTime.now(),
        createdBy: user.uid,
      );

      final docRef = await _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('coupons')
          .add(coupon.toFirestore());

      if (kDebugMode) {
        print('✅ [Coupon] Created coupon: ${coupon.code}');
      }

      return coupon.copyWith(id: docRef.id);
    } catch (e) {
      if (kDebugMode) {
        print('❌ [Coupon] Error creating coupon: $e');
      }
      rethrow;
    }
  }

  /// Update coupon
  static Future<void> updateCoupon({
    required String facilityId,
    required String couponId,
    String? name,
    String? description,
    CouponType? type,
    double? value,
    CouponStatus? status,
    DateTime? validFrom,
    DateTime? validUntil,
    int? maxUses,
    double? minPurchaseAmount,
    bool? appliesToRent,
    bool? appliesToFees,
    bool? appliesToInsurance,
  }) async {
    try {
      final user = _auth.currentUser;
      if (user == null) throw Exception('User not authenticated');

      final updates = <String, dynamic>{
        'updatedAt': FieldValue.serverTimestamp(),
      };

      if (name != null) updates['name'] = name;
      if (description != null) updates['description'] = description;
      if (type != null) updates['type'] = type.name;
      if (value != null) updates['value'] = value;
      if (status != null) updates['status'] = status.name;
      if (validFrom != null) updates['validFrom'] = Timestamp.fromDate(validFrom);
      if (validUntil != null) updates['validUntil'] = Timestamp.fromDate(validUntil);
      if (maxUses != null) updates['maxUses'] = maxUses;
      if (minPurchaseAmount != null) updates['minPurchaseAmount'] = minPurchaseAmount;
      if (appliesToRent != null) updates['appliesToRent'] = appliesToRent;
      if (appliesToFees != null) updates['appliesToFees'] = appliesToFees;
      if (appliesToInsurance != null) updates['appliesToInsurance'] = appliesToInsurance;

      await _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('coupons')
          .doc(couponId)
          .update(updates);

      if (kDebugMode) {
        print('✅ [Coupon] Updated coupon: $couponId');
      }
    } catch (e) {
      if (kDebugMode) {
        print('❌ [Coupon] Error updating coupon: $e');
      }
      rethrow;
    }
  }

  /// Increment coupon usage count
  static Future<void> incrementCouponUsage({
    required String facilityId,
    required String couponId,
  }) async {
    try {
      await _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('coupons')
          .doc(couponId)
          .update({
        'currentUses': FieldValue.increment(1),
        'updatedAt': FieldValue.serverTimestamp(),
      });

      // Check if max uses reached
      final doc = await _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('coupons')
          .doc(couponId)
          .get();

      if (doc.exists) {
        final data = doc.data()!;
        final maxUses = data['maxUses'];
        final currentUses = data['currentUses'] ?? 0;

        if (maxUses != null && currentUses >= maxUses) {
          await _firestore
              .collection('facilities')
              .doc(facilityId)
              .collection('coupons')
              .doc(couponId)
              .update({
            'status': CouponStatus.usedUp.name,
          });
        }
      }
    } catch (e) {
      if (kDebugMode) {
        print('❌ [Coupon] Error incrementing coupon usage: $e');
      }
      rethrow;
    }
  }

  /// Delete coupon (soft delete)
  static Future<void> deleteCoupon({
    required String facilityId,
    required String couponId,
  }) async {
    try {
      final user = _auth.currentUser;
      if (user == null) throw Exception('User not authenticated');

      await _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('coupons')
          .doc(couponId)
          .update({
        'isActive': false,
        'status': CouponStatus.inactive.name,
        'updatedAt': FieldValue.serverTimestamp(),
      });

      if (kDebugMode) {
        print('✅ [Coupon] Deleted coupon: $couponId');
      }
    } catch (e) {
      if (kDebugMode) {
        print('❌ [Coupon] Error deleting coupon: $e');
      }
      rethrow;
    }
  }
}

