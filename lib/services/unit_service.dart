import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import '../models/unit_model.dart';
import 'facility_limits_service.dart';

class UnitService {
  static final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  static final FirebaseAuth _auth = FirebaseAuth.instance;

  // Create a new unit in facility subcollection
  static Future<String> createUnit({
    required String facilityId,
    required String unitNumber,
    required String unitType,
    required double monthlyRate,
    String? description,
    Map<String, dynamic>? dimensions,
    List<String>? features,
    String? notes,
    double? securityDeposit,
    Map<String, dynamic>? customFields,
  }) async {
    try {
      final user = _auth.currentUser;
      if (user == null) {
        throw Exception('Not signed in');
      }

      // Check facility unit limit (hard cap)
      final canAdd = await FacilityLimitsService.canAddUnit(facilityId);
      if (!canAdd) {
        final currentCount = await FacilityLimitsService.getUnitCount(facilityId);
        throw Exception(
          'Unit limit reached. This facility has reached the maximum of ${FacilityLimitsService.maxUnitsPerFacility} units. '
          'Current count: $currentCount. Please contact support if you need to increase your limit.'
        );
      }

      if (kDebugMode) {
        print('🔄 Creating unit: $unitNumber for facility: $facilityId');
      }

      // Check if unit number already exists in facility
      final existingUnit = await _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('units')
          .where('unitNumber', isEqualTo: unitNumber)
          .get();

      if (existingUnit.docs.isNotEmpty) {
        throw Exception('Unit number $unitNumber already exists in this facility');
      }

      final ref = _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('units')
          .doc();

      final unitData = {
        'facilityId': facilityId,
        'unitNumber': unitNumber,
        'unitType': unitType,
        'status': 'available',
        'monthlyRate': monthlyRate,
        'securityDeposit': securityDeposit,
        'description': description,
        'dimensions': dimensions,
        'features': features,
        'notes': notes,
        'customFields': customFields,
        'createdAt': FieldValue.serverTimestamp(),
        'updatedAt': FieldValue.serverTimestamp(),
        'createdBy': user.uid,
        'isActive': true,
      };

      await ref.set(unitData);

      if (kDebugMode) {
        print('✅ Unit created successfully: ${ref.id}');
      }

      return ref.id;
    } catch (e) {
      if (kDebugMode) {
        print('❌ Error creating unit: $e');
      }
      rethrow;
    }
  }

  // Get all units for a facility (real-time stream)
  static Stream<List<UnitModel>> getUnitsForFacilityStream(String facilityId) {
    try {
      final user = _auth.currentUser;
      if (user == null) {
        throw Exception('Not signed in');
      }

      if (kDebugMode) {
        print('🔄 Setting up units stream for facility: $facilityId');
      }

      Query query = _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('units')
          .limit(400); // Hard cap: 400 units per facility
      
      // Try ordered query, fall back to unordered if index is building
      try {
        query = query.orderBy('unitNumber');
      } catch (orderingError) {
        if (kDebugMode) {
          print('⚠️ Ordered query not available, using unordered: $orderingError');
        }
      }

      return query.snapshots().map((snapshot) {
        final units = snapshot.docs.map((doc) {
          return UnitModel.fromFirestore(doc);
        }).toList();

        // Sort in memory if we used fallback query
        units.sort((a, b) => a.unitNumber.compareTo(b.unitNumber));

        if (kDebugMode) {
          print('📡 Stream update: ${units.length} units for facility: $facilityId');
        }

        return units;
      });
    } catch (e) {
      if (kDebugMode) {
        print('❌ Error setting up units stream: $e');
      }
      rethrow;
    }
  }

  // Get all units for a facility
  static Future<List<UnitModel>> getUnitsForFacility(String facilityId) async {
    try {
      final user = _auth.currentUser;
      if (user == null) {
        throw Exception('Not signed in');
      }

      if (kDebugMode) {
        print('🔄 Getting units for facility: $facilityId');
      }

      // Try ordered query first, fall back to unordered if index is building
      QuerySnapshot snapshot;
      try {
        snapshot = await _firestore
            .collection('facilities')
            .doc(facilityId)
            .collection('units')
            .orderBy('unitNumber')
            .limit(400) // Hard cap: 400 units per facility
            .get();
      } catch (orderingError) {
        if (orderingError.toString().contains('failed-precondition') && orderingError.toString().contains('index')) {
          if (kDebugMode) {
            print('📋 INDEX BUILDING: Using fallback unordered query for units...');
          }
          // Fallback to unordered query
          snapshot = await _firestore
              .collection('facilities')
              .doc(facilityId)
              .collection('units')
              .limit(400) // Hard cap: 400 units per facility
              .get();
        } else {
          rethrow;
        }
      }

      if (kDebugMode) {
        print('✅ Successfully retrieved ${snapshot.docs.length} units');
      }

      final units = snapshot.docs
          .map((doc) => UnitModel.fromFirestore(doc))
          .toList();
          
      // Sort in memory (needed for fallback queries)
      units.sort((a, b) => a.unitNumber.compareTo(b.unitNumber));
      
      return units;
    } catch (e) {
      if (kDebugMode) {
        print('❌ Error getting units: $e');
      }
      return [];
    }
  }

  // Get a specific unit
  static Future<UnitModel?> getUnit(String facilityId, String unitId) async {
    try {
      final user = _auth.currentUser;
      if (user == null) {
        throw Exception('Not signed in');
      }

      final doc = await _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('units')
          .doc(unitId)
          .get();

      if (!doc.exists) {
        return null;
      }

      return UnitModel.fromFirestore(doc);
    } catch (e) {
      if (kDebugMode) {
        print('❌ Error getting unit: $e');
      }
      return null;
    }
  }

  // Update unit
  static Future<void> updateUnit({
    required String facilityId,
    required String unitId,
    String? unitNumber,
    String? unitType,
    UnitStatus? status,
    String? tenantId,
    String? tenantName,
    double? monthlyRate,
    double? securityDeposit,
    String? description,
    Map<String, dynamic>? dimensions,
    List<String>? features,
    String? notes,
    DateTime? lastMaintenance,
    DateTime? nextMaintenance,
    DateTime? moveInDate,
    DateTime? moveOutDate,
    DateTime? reservationExpiry,
    String? reservedBy,
    Map<String, dynamic>? customFields,
    double? mapX,
    double? mapY,
    double? mapWidth,
    double? mapHeight,
  }) async {
    try {
      final user = _auth.currentUser;
      if (user == null) {
        throw Exception('Not signed in');
      }

      if (kDebugMode) {
        print('🔄 Updating unit: $unitId');
      }

      final updateData = <String, dynamic>{
        'updatedAt': FieldValue.serverTimestamp(),
        'updatedBy': user.uid,
      };

      if (unitNumber != null) updateData['unitNumber'] = unitNumber;
      if (unitType != null) updateData['unitType'] = unitType;
      
      // Handle status and tenant data with proper guards
      final finalStatus = status;
      if (finalStatus != null) {
        updateData['status'] = finalStatus.name;
        // Guard: When status is "available", explicitly clear tenant data
        if (finalStatus == UnitStatus.available) {
          updateData['tenantId'] = FieldValue.delete();
          updateData['tenantName'] = FieldValue.delete();
          updateData['moveInDate'] = FieldValue.delete();
          updateData['moveOutDate'] = FieldValue.serverTimestamp();
        } else {
          // When status is NOT "available", allow tenant assignment
          if (tenantId != null) updateData['tenantId'] = tenantId;
          if (tenantName != null) updateData['tenantName'] = tenantName;
        }
      } else {
        // Status not changing - allow tenant updates independently
        if (tenantId != null) updateData['tenantId'] = tenantId;
        if (tenantName != null) updateData['tenantName'] = tenantName;
      }
      if (monthlyRate != null) updateData['monthlyRate'] = monthlyRate;
      if (securityDeposit != null) updateData['securityDeposit'] = securityDeposit;
      if (description != null) updateData['description'] = description;
      if (dimensions != null) updateData['dimensions'] = dimensions;
      if (features != null) updateData['features'] = features;
      if (notes != null) updateData['notes'] = notes;
      if (lastMaintenance != null) updateData['lastMaintenance'] = Timestamp.fromDate(lastMaintenance);
      if (nextMaintenance != null) updateData['nextMaintenance'] = Timestamp.fromDate(nextMaintenance);
      if (moveInDate != null) updateData['moveInDate'] = Timestamp.fromDate(moveInDate);
      if (moveOutDate != null) updateData['moveOutDate'] = Timestamp.fromDate(moveOutDate);
      if (reservationExpiry != null) updateData['reservationExpiry'] = Timestamp.fromDate(reservationExpiry);
      if (reservedBy != null) updateData['reservedBy'] = reservedBy;
      if (customFields != null) updateData['customFields'] = customFields;
      // Handle map layout updates - merge with existing layout if only partial update
      if (mapX != null || mapY != null || mapWidth != null || mapHeight != null) {
        // Get existing layout data if available (we'll merge it)
        // For now, always send the complete layout object since _persistLayoutForUnit always sends all values
        // But this ensures backward compatibility if we ever need partial updates
        updateData['mapLayout'] = {
          if (mapX != null) 'x': mapX,
          if (mapY != null) 'y': mapY,
          if (mapWidth != null) 'width': mapWidth,
          if (mapHeight != null) 'height': mapHeight,
        };
      }

      await _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('units')
          .doc(unitId)
          .update(updateData);

      if (kDebugMode) {
        print('✅ Unit updated successfully: $unitId');
      }
    } catch (e) {
      if (kDebugMode) {
        print('❌ Error updating unit: $e');
      }
      rethrow;
    }
  }

  // Assign tenant to unit
  static Future<void> assignTenantToUnit({
    required String facilityId,
    required String unitId,
    required String tenantId,
    required String tenantName,
    DateTime? moveInDate,
  }) async {
    try {
      final user = _auth.currentUser;
      if (user == null) {
        throw Exception('Not signed in');
      }

      if (kDebugMode) {
        print('🔄 Assigning tenant $tenantName to unit $unitId');
      }

      await updateUnit(
        facilityId: facilityId,
        unitId: unitId,
        status: UnitStatus.occupied,
        tenantId: tenantId,
        tenantName: tenantName,
        moveInDate: moveInDate ?? DateTime.now(),
      );

      if (kDebugMode) {
        print('✅ Tenant assigned to unit successfully');
      }
    } catch (e) {
      if (kDebugMode) {
        print('❌ Error assigning tenant to unit: $e');
      }
      rethrow;
    }
  }

  // Remove tenant from unit
  static Future<void> removeTenantFromUnit({
    required String facilityId,
    required String unitId,
    DateTime? moveOutDate,
  }) async {
    try {
      final user = _auth.currentUser;
      if (user == null) {
        throw Exception('Not signed in');
      }

      if (kDebugMode) {
        print('🔄 Removing tenant from unit $unitId');
      }

      // Explicitly delete tenant fields and set status to available
      final updateData = <String, dynamic>{
        'status': UnitStatus.available.name,
        'tenantId': FieldValue.delete(),
        'tenantName': FieldValue.delete(),
        'moveInDate': FieldValue.delete(),
        'moveOutDate': moveOutDate != null 
            ? Timestamp.fromDate(moveOutDate) 
            : FieldValue.serverTimestamp(),
        'updatedAt': FieldValue.serverTimestamp(),
        'updatedBy': user.uid,
      };

      await _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('units')
          .doc(unitId)
          .update(updateData);

      if (kDebugMode) {
        print('✅ Tenant removed from unit successfully');
      }
    } catch (e) {
      if (kDebugMode) {
        print('❌ Error removing tenant from unit: $e');
      }
      rethrow;
    }
  }

  // Archive unit (soft delete)
  static Future<void> archiveUnit(String facilityId, String unitId) async {
    try {
      final user = _auth.currentUser;
      if (user == null) {
        throw Exception('Not signed in');
      }

      if (kDebugMode) {
        print('🔄 Archiving unit: $unitId');
      }

      await _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('units')
          .doc(unitId)
          .update({
        'isActive': false,
        'archivedAt': FieldValue.serverTimestamp(),
        'archivedByUid': user.uid,
        'updatedAt': FieldValue.serverTimestamp(),
      });

      if (kDebugMode) {
        print('✅ Unit archived successfully: $unitId');
      }
    } catch (e) {
      if (kDebugMode) {
        print('❌ Error archiving unit: $e');
      }
      rethrow;
    }
  }

  // Delete unit (hard delete)
  static Future<void> deleteUnit(String facilityId, String unitId) async {
    try {
      final user = _auth.currentUser;
      if (user == null) {
        throw Exception('Not signed in');
      }

      if (kDebugMode) {
        print('🔄 Deleting unit: $unitId');
      }

      await _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('units')
          .doc(unitId)
          .delete();

      if (kDebugMode) {
        print('✅ Unit deleted successfully: $unitId');
      }
    } catch (e) {
      if (kDebugMode) {
        print('❌ Error deleting unit: $e');
      }
      rethrow;
    }
  }

  // Get available units for a facility
  static Future<List<UnitModel>> getAvailableUnits(String facilityId) async {
    try {
      final user = _auth.currentUser;
      if (user == null) {
        throw Exception('Not signed in');
      }

      if (kDebugMode) {
        print('🔄 Getting available units for facility: $facilityId');
      }

      final snapshot = await _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('units')
          .where('isActive', isEqualTo: true)
          .where('status', isEqualTo: 'available')
          .orderBy('unitNumber')
          .get();

      final units = snapshot.docs
          .map((doc) => UnitModel.fromFirestore(doc))
          .toList();

      if (kDebugMode) {
        print('✅ Found ${units.length} available units');
      }

      return units;
    } catch (e) {
      if (kDebugMode) {
        print('❌ Error getting available units: $e');
      }
      return [];
    }
  }

  // Check if unit number exists in facility
  static Future<bool> unitNumberExists(String facilityId, String unitNumber) async {
    try {
      final snapshot = await _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('units')
          .where('unitNumber', isEqualTo: unitNumber)
          .where('isActive', isEqualTo: true)
          .get();

      return snapshot.docs.isNotEmpty;
    } catch (e) {
      if (kDebugMode) {
        print('❌ Error checking unit number: $e');
      }
      return false;
    }
  }
}