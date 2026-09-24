import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import '../models/unit_model.dart';
import 'audit_service.dart';
import 'facility_limits_service.dart';
import 'facility_map_v2_service.dart';
import 'package:sfcapp/services/facility_subcollections.dart';
import 'package:sfcapp/services/tenant_service.dart';

class UnitService {
  static final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  // A getter, not a final field, so tests can sign a fake user in and run
  // the real read code (see authForTesting).
  static FirebaseAuth get _auth => _authForTesting ?? FirebaseAuth.instance;
  static FirebaseAuth? _authForTesting;

  @visibleForTesting
  static set authForTesting(FirebaseAuth? auth) => _authForTesting = auth;

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
    bool publicListingEnabled = true,
    bool internalUse = false,
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

      // Check if unit number already exists in facility. Through
      // FacilitySubcollections, like the reads, so tests run this write.
      final unitsRef = FacilitySubcollections.units(facilityId);
      final existingUnit =
          await unitsRef.where('unitNumber', isEqualTo: unitNumber).get();

      if (existingUnit.docs.isNotEmpty) {
        throw Exception('Unit number $unitNumber already exists in this facility');
      }

      final ref = unitsRef.doc();

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
        'publicListingEnabled': publicListingEnabled,
        'internalUse': internalUse,
      };

      await ref.set(unitData);

      if (kDebugMode) {
        print('✅ Unit created successfully: ${ref.id}');
      }

      _schedulePublicMapInventorySync(facilityId);

      return ref.id;
    } catch (e) {
      if (kDebugMode) {
        print('❌ Error creating unit: $e');
      }
      rethrow;
    }
  }

  /// Most unit docs one facility read returns; see
  /// [FacilitySubcollections.readLimit].
  ///
  /// It was 400, ordered by unitNumber, with archived units dropped only after
  /// the cap. Archived units used up the cap, docs with no unitNumber were
  /// left out of the ordered query, and the Cloud Function that mirrors the
  /// counts reads every unit, so the dashboard, the Units list and the
  /// facility cards undercounted against it.
  static const int facilityUnitReadLimit = FacilitySubcollections.readLimit;

  /// A facility's non-archived units by unit number, from one unordered read.
  ///
  /// No auth check: callers check the signed-in user first. The public map
  /// publish and inventory refresh (FacilityMapV2Service) read through it
  /// too, so every unit list applies the same rule.
  static Future<List<UnitModel>> readFacilityUnits(String facilityId) async {
    final snapshot = await FacilitySubcollections.units(facilityId)
        .limit(facilityUnitReadLimit)
        .get();
    return _unitsFromRead(facilityId, snapshot.docs);
  }

  /// Non-archived units, archived ones dropped from the whole read rather
  /// than after a cap, sorted by unit number client-side (the read is
  /// unordered so docs without a unitNumber are not left out).
  ///
  /// `(archived ?? false) == false` is the test the facility stats Cloud
  /// Function applies (`countsTowardOccupancy`), so a stray non-boolean is dropped
  /// by both.
  static List<UnitModel> _unitsFromRead(
    String facilityId,
    List<DocumentSnapshot<Map<String, dynamic>>> docs,
  ) {
    FacilitySubcollections.reportIfReadLimitReached(
      facilityId,
      'unit',
      docs.length,
    );
    final units = [
      for (final doc in docs)
        if ((doc.data()?['archived'] ?? false) == false)
          UnitModel.fromFirestore(doc),
    ];
    units.sort((a, b) => a.unitNumber.compareTo(b.unitNumber));
    if (kDebugMode) {
      debugPrint('📡 ${units.length} active units '
          '(${docs.length - units.length} archived) for facility: $facilityId');
    }
    return units;
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

      return FacilitySubcollections.units(facilityId)
          .limit(facilityUnitReadLimit)
          .snapshots()
          .map((snapshot) => _unitsFromRead(facilityId, snapshot.docs));
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

      return await readFacilityUnits(facilityId);
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
    bool? publicListingEnabled,
    bool? internalUse,
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
      if (publicListingEnabled != null) {
        updateData['publicListingEnabled'] = publicListingEnabled;
      }
      if (internalUse != null) updateData['internalUse'] = internalUse;
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

      // Through FacilitySubcollections, like the reads, so tests run this
      // write.
      final unitRef = FacilitySubcollections.units(facilityId).doc(unitId);

      // Get before snapshot for audit log (especially for status changes)
      final beforeDoc = await unitRef.get();
      final beforeData = beforeDoc.exists ? beforeDoc.data() : null;
      final beforeStatus = beforeData?['status'] as String?;
      // Read as UnitModel does: only an exact true.
      final beforeInternalUse = beforeData?['internalUse'] == true;

      await unitRef.update(updateData);

      // Get after snapshot for audit log
      final afterDoc = await unitRef.get();
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

      // Internal use takes a unit out of Total, Occupied and Vacant and off
      // the website, so a change to it moves reported occupancy; it was not
      // logged.
      final afterInternalUse = afterData?['internalUse'] == true;
      if (internalUse != null && beforeInternalUse != afterInternalUse) {
        await AuditService.logEvent(
          facilityId: facilityId,
          eventType: 'unit.internalUseChanged',
          targetType: 'unit',
          targetId: unitId,
          before: {'internalUse': beforeInternalUse},
          after: {'internalUse': afterInternalUse},
          metadata: {'unitNumber': afterData?['unitNumber']},
        );
      }

      if (kDebugMode) {
        print('✅ Unit updated successfully: $unitId');
      }

      final shouldSyncPublicInventory = unitNumber != null ||
          unitType != null ||
          status != null ||
          tenantId != null ||
          tenantName != null ||
          monthlyRate != null ||
          description != null ||
          dimensions != null ||
          features != null;
      if (shouldSyncPublicInventory) {
        _schedulePublicMapInventorySync(facilityId);
      }
    } catch (e) {
      if (kDebugMode) {
        print('❌ Error updating unit: $e');
      }
      rethrow;
    }
  }

  // Assign tenant to unit (Units > unit > Assign Tenant, and a tenant picked
  // in Edit Unit). Through TenantService.assignUnit, which gives the tenant
  // the unit in the same transaction: its rate added to theirs, their unit
  // number set. It used to write the unit only, so the tenant was never
  // billed for it. Returns the rent notice for the screen, or null.
  // [records] and [effects] are for tests.
  static Future<String?> assignTenantToUnit({
    required String facilityId,
    required String unitId,
    required String tenantId,
    required String tenantName,
    DateTime? moveInDate,
    UnitStatus status = UnitStatus.occupied,
    TenantRecordsStore? records,
    TenantUpdateEffects? effects,
  }) async {
    try {
      final user = _auth.currentUser;
      if (user == null) {
        throw Exception('Not signed in');
      }

      if (kDebugMode) {
        print('🔄 Assigning tenant $tenantName to unit $unitId');
      }

      final notice = await TenantService.assignUnit(
        records ?? TenantService.recordsFor(facilityId),
        facilityId: facilityId,
        unitId: unitId,
        tenantId: tenantId,
        uid: user.uid,
        status: status,
        moveInDate: moveInDate ?? DateTime.now(),
        effects: effects,
      );

      if (kDebugMode) {
        print('✅ Tenant assigned to unit successfully');
      }
      // No client stats refresh: the unit write above fires the onUnitWrite
      // Cloud Function, which recomputes. The awaited client recompute here
      // cost ~6 reads per save and its stats write was always denied.
      _schedulePublicMapInventorySync(facilityId);
      return notice;
    } catch (e) {
      if (kDebugMode) {
        print('❌ Error assigning tenant to unit: $e');
      }
      rethrow;
    }
  }

  /// The unit fields [removeTenantFromUnit] writes: tenant fields deleted,
  /// status available. Shared so a batched unlink (tenant delete) makes the
  /// same change as Unassign Tenant.
  static Map<String, dynamic> tenantUnlinkFields({
    required String updatedBy,
    DateTime? moveOutDate,
  }) {
    return <String, dynamic>{
      'status': UnitStatus.available.name,
      'tenantId': FieldValue.delete(),
      'tenantName': FieldValue.delete(),
      'moveInDate': FieldValue.delete(),
      'moveOutDate': moveOutDate != null
          ? Timestamp.fromDate(moveOutDate)
          : FieldValue.serverTimestamp(),
      'updatedAt': FieldValue.serverTimestamp(),
      'updatedBy': updatedBy,
    };
  }

  // Remove tenant from unit (Unassign Tenant). The tenant's side changes in
  // the same transaction: see TenantService.unassignUnit. Returns the rent
  // notice for the screen, or null. [records] is for tests.
  static Future<String?> removeTenantFromUnit({
    required String facilityId,
    required String unitId,
    DateTime? moveOutDate,
    TenantRecordsStore? records,
  }) async {
    try {
      final user = _auth.currentUser;
      if (user == null) {
        throw Exception('Not signed in');
      }

      if (kDebugMode) {
        print('🔄 Removing tenant from unit $unitId');
      }

      final notice = await TenantService.unassignUnit(
        records ?? TenantService.recordsFor(facilityId),
        unitId: unitId,
        uid: user.uid,
        moveOutDate: moveOutDate,
      );

      if (kDebugMode) {
        print('✅ Tenant removed from unit successfully');
      }
      // Stats: recomputed by the onUnitWrite Cloud Function, as above.
      _schedulePublicMapInventorySync(facilityId);
      return notice;
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
        'archived': true, // Add archived flag for filtering
        'archivedAt': FieldValue.serverTimestamp(),
        'archivedByUid': user.uid,
        'updatedAt': FieldValue.serverTimestamp(),
      });

      if (kDebugMode) {
        print('✅ Unit archived successfully: $unitId');
      }
      _schedulePublicMapInventorySync(facilityId);
    } catch (e) {
      if (kDebugMode) {
        print('❌ Error archiving unit: $e');
      }
      rethrow;
    }
  }

  /// For callers that change units in their own batch (tenant delete).
  static void schedulePublicMapInventorySync(String facilityId) =>
      _schedulePublicMapInventorySync(facilityId);

  static void _schedulePublicMapInventorySync(String facilityId) {
    FacilityMapV2Service.refreshPublicMapInventoryFromLiveUnits(facilityId)
        .catchError((Object e) {
      if (kDebugMode) {
        print('⚠️ [UnitService] public map inventory sync: $e');
      }
    });
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

      final unitRef = _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('units')
          .doc(unitId);
      final beforeSnap = await unitRef.get();
      final beforeData = beforeSnap.exists && beforeSnap.data() != null
          ? Map<String, dynamic>.from(beforeSnap.data()!)
          : null;

      await unitRef.delete();

      await AuditService.logEvent(
        facilityId: facilityId,
        eventType: 'unit.deleted',
        targetType: 'unit',
        targetId: unitId,
        tenantId: beforeData?['tenantId'] as String?,
        before: beforeData,
        metadata: {
          if (beforeData != null && beforeData['unitNumber'] != null)
            'unitNumber': beforeData['unitNumber'],
        },
      );

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