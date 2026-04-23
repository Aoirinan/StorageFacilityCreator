import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';

/// Service for enforcing facility resource limits (hard caps)
/// Prevents abuse and controls costs
class FacilityLimitsService {
  static final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  // Hard caps (enforced limits)
  static const int maxTenantsPerFacility = 250;
  static const int maxUnitsPerFacility = 200;
  static const int maxMapShapesPerFacility = 300;
  static const int maxContractsPerFacility = 250;

  /// Check if facility can add more tenants
  static Future<bool> canAddTenant(String facilityId) async {
    try {
      final count = await _getTenantCount(facilityId);
      return count < maxTenantsPerFacility;
    } catch (e) {
      if (kDebugMode) {
        print('❌ Error checking tenant limit: $e');
      }
      // On error, allow operation (fail open) but log
      return true;
    }
  }

  /// Get current tenant count for a facility
  static Future<int> getTenantCount(String facilityId) async {
    return await _getTenantCount(facilityId);
  }

  static Future<int> _getTenantCount(String facilityId) async {
    final snapshot = await _firestore
        .collection('facilities')
        .doc(facilityId)
        .collection('tenants')
        .count()
        .get();
    return snapshot.count ?? 0;
  }

  /// Check if facility can add more units
  static Future<bool> canAddUnit(String facilityId) async {
    try {
      final count = await _getUnitCount(facilityId);
      return count < maxUnitsPerFacility;
    } catch (e) {
      if (kDebugMode) {
        print('❌ Error checking unit limit: $e');
      }
      return true;
    }
  }

  /// Get current unit count for a facility
  static Future<int> getUnitCount(String facilityId) async {
    return await _getUnitCount(facilityId);
  }

  static Future<int> _getUnitCount(String facilityId) async {
    final snapshot = await _firestore
        .collection('facilities')
        .doc(facilityId)
        .collection('units')
        .count()
        .get();
    return snapshot.count ?? 0;
  }

  /// Check if facility can add more map shapes
  static Future<bool> canAddMapShape(String facilityId) async {
    try {
      final count = await _getMapShapeCount(facilityId);
      return count < maxMapShapesPerFacility;
    } catch (e) {
      if (kDebugMode) {
        print('❌ Error checking map shape limit: $e');
      }
      return true;
    }
  }

  /// Get current map shape count for a facility
  static Future<int> getMapShapeCount(String facilityId) async {
    return await _getMapShapeCount(facilityId);
  }

  static Future<int> _getMapShapeCount(String facilityId) async {
    final snapshot = await _firestore
        .collection('facilities')
        .doc(facilityId)
        .collection('mapShapes')
        .count()
        .get();
    return snapshot.count ?? 0;
  }

  /// Check if facility can add more contracts
  static Future<bool> canAddContract(String facilityId) async {
    try {
      final count = await _getContractCount(facilityId);
      return count < maxContractsPerFacility;
    } catch (e) {
      if (kDebugMode) {
        print('❌ Error checking contract limit: $e');
      }
      return true;
    }
  }

  /// Get current contract count for a facility
  static Future<int> getContractCount(String facilityId) async {
    return await _getContractCount(facilityId);
  }

  static Future<int> _getContractCount(String facilityId) async {
    final snapshot = await _firestore
        .collection('facilities')
        .doc(facilityId)
        .collection('contracts')
        .count()
        .get();
    return snapshot.count ?? 0;
  }

  /// Get user-friendly limit message
  static String getLimitMessage(String resourceType, int current, int max) {
    final remaining = max - current;
    if (remaining <= 0) {
      return 'You have reached the maximum limit of $max $resourceType per facility. Please contact support if you need to increase your limit.';
    } else if (remaining <= 10) {
      return 'You have $remaining $resourceType remaining (limit: $max per facility).';
    }
    return ''; // No message needed if plenty of space
  }
}

