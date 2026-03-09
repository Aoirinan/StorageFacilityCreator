import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import '../models/unit_model.dart';
import 'audit_service.dart';
import 'facility_limits_service.dart';
import 'facility_stats_service.dart';

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
        'archived': false, // Default to not archived
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
        
        // Filter out archived units (treat missing archived field as false/not archived)
        final activeUnits = units.where((unit) {
          // Check if unit has archived field and filter accordingly
          final data = snapshot.docs.firstWhere((doc) => doc.id == unit.id).data() as Map<String, dynamic>?;
          final archived = data?['archived'] ?? false;
          return archived == false;
        }).toList();

        // Sort in memory if we used fallback query
        activeUnits.sort((a, b) => a.unitNumber.compareTo(b.unitNumber));

        if (kDebugMode) {
          print('📡 Stream update: ${activeUnits.length} active units (${units.length - activeUnits.length} archived) for facility: $facilityId');
        }

        return activeUnits;
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
      
      // Filter out archived units in memory (treat missing archived field as false/not archived)
      final allDocs = snapshot.docs;
      final activeDocs = allDocs.where((doc) {
        final data = doc.data() as Map<String, dynamic>?;
        final archived = data?['archived'] ?? false;
        return archived == false;
      }).toList();

      if (kDebugMode) {
        print('✅ Successfully retrieved ${activeDocs.length} active units (${allDocs.length - activeDocs.length} archived)');
      }

      final units = activeDocs
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

      // Get before snapshot for audit log (especially for status changes)
      final beforeDoc = await _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('units')
          .doc(unitId)
          .get();
      final beforeData = beforeDoc.exists ? beforeDoc.data() : null;
      final beforeStatus = beforeData?['status'] as String?;

      await _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('units')
          .doc(unitId)
          .update(updateData);

      // Get after snapshot for audit log
      final afterDoc = await _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('units')
          .doc(unitId)
          .get();
      final afterData = afterDoc.exists ? afterDoc.data() : null;
      final afterStatus = afterData?['status'] as String?;

      // Log audit event if status changed
      if (status != null && beforeStatus != afterStatus) {
        await AuditService.logEvent(
          facilityId: facilityId,
          eventType: 'unit.statusChanged',
          targetType: 'unit',
          targetId: unitId,
          tenantId: tenantId,
          before: beforeData != null ? {'status': beforeStatus} : null,
          after: afterData != null ? {'status': afterStatus} : null,
          metadata: {
            'unitNumber': afterData?['unitNumber'],
            'oldStatus': beforeStatus,
            'newStatus': afterStatus,
          },
        );
      }

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
      await FacilityStatsService.updateFacilityStats(facilityId);
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
      await FacilityStatsService.updateFacilityStats(facilityId);
    } catch (e) {
      if (kDebugMode) {
        print('❌ Error removing tenant from unit: $e');
      }
      rethrow;
    }
  }

  /// Batch-clear tenant link and set status to available for multiple units.
  /// Used by occupancy healing; does NOT call FacilityStatsService (caller must recompute).
  /// Firestore batch limit 500; chunks if needed.
  static Future<void> clearTenantFromUnitsBatch({
    required String facilityId,
    required List<String> unitIds,
  }) async {
    if (unitIds.isEmpty) return;
    final user = _auth.currentUser;
    if (user == null) throw Exception('Not signed in');

    const batchLimit = 500;
    final ref = _firestore.collection('facilities').doc(facilityId).collection('units');
    for (var i = 0; i < unitIds.length; i += batchLimit) {
      final chunk = unitIds.sublist(i, (i + batchLimit).clamp(0, unitIds.length));
      final batch = _firestore.batch();
      for (final unitId in chunk) {
        batch.update(ref.doc(unitId), {
          'status': UnitStatus.available.name,
          'tenantId': FieldValue.delete(),
          'tenantName': FieldValue.delete(),
          'updatedAt': FieldValue.serverTimestamp(),
          'updatedBy': user.uid,
        });
      }
      await batch.commit();
    }
    if (kDebugMode) {
      print('✅ [UnitService] Cleared tenant from ${unitIds.length} unit(s) (heal batch)');
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
        'archived': true, // Add archived flag for filtering
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