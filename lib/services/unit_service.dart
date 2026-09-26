import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:sfcapp/models/tenant_model.dart';
import '../models/unit_model.dart';
import 'audit_service.dart';
import 'facility_limits_service.dart';
import 'facility_map_v2_service.dart';
import 'package:sfcapp/services/facility_subcollections.dart';
import 'package:sfcapp/services/tenant_service.dart';
import 'package:sfcapp/utils/error_message_helper.dart';
import 'package:sfcapp/utils/unit_areas.dart';
import 'package:sfcapp/utils/unit_number.dart';

/// A unit number another unit in the facility already has, trimmed and
/// ignoring case. The check was exact, so "12a" beside "12A" (or a rename
/// onto another unit's number, which was not checked at all) made two units
/// a tenant's unit number could mean.
class DuplicateUnitNumberException implements UserFacingException {
  const DuplicateUnitNumberException({
    required this.unitNumber,
    required this.existingNumber,
    this.archived = false,
    this.area,
  });

  /// The number asked for.
  final String unitNumber;

  /// The other unit's number as stored.
  final String existingNumber;

  /// Whether the other unit is archived (or switched off): it is in no
  /// list, so the number looks free, but archived units keep theirs.
  final bool archived;

  /// The area both units are in, when the facility repeats unit numbers
  /// across areas (the number is then only taken within that area). Null
  /// when numbers are unique across the facility.
  final String? area;

  @override
  String get message {
    final existing = existingNumber.trim();
    final spelled = existing == unitNumber ? '' : ' (as $existing)';
    final inArea = area;
    if (inArea != null) {
      if (archived) {
        return 'Unit number $unitNumber in $inArea belongs to an archived '
            'unit$spelled. Nothing was saved. Use a different number or '
            'area: archived units keep theirs.';
      }
      return 'Unit number $unitNumber already exists in $inArea$spelled. '
          'Nothing was saved. Use a different number or area.';
    }
    if (archived) {
      return 'Unit number $unitNumber belongs to an archived unit$spelled. '
          'Nothing was saved. Use a different number: archived units keep '
          'theirs.';
    }
    return 'Unit number $unitNumber already exists in this facility$spelled. '
        'Nothing was saved. Use a different number.';
  }

  @override
  String toString() => message;
}

/// A unit number more than one unit has, in a facility that repeats unit
/// numbers across areas (`unitNumbersRepeatAcrossAreas`), where one of those
/// units has no area: nothing would tell them apart on a statement, an
/// invoice or a text.
class UnitNumberNeedsAreaException implements UserFacingException {
  const UnitNumberNeedsAreaException({
    required this.unitNumber,
    this.otherArea,
    this.otherUnitHasNoArea = false,
    this.clearingArea = false,
  });

  /// The number, trimmed.
  final String unitNumber;

  /// The area of another unit with the number, when it has one.
  final String? otherArea;

  /// The unit being saved has an area, but another unit with the number
  /// has none: that unit needs one first.
  final bool otherUnitHasNoArea;

  /// The area is being removed from (or changed to blank on) a unit whose
  /// number another unit also has.
  final bool clearingArea;

  @override
  String get message {
    if (otherUnitHasNoArea) {
      return 'Unit number $unitNumber is already used by a unit with no '
          'area. Nothing was saved. Give that unit an area first (Units > '
          'unit $unitNumber > Edit), then this unit can use the number too.';
    }
    final where = otherArea == null ? '' : ' (in $otherArea)';
    if (clearingArea) {
      return 'Unit $unitNumber needs an area: another unit is also numbered '
          '$unitNumber$where. Nothing was saved. Keep an area on this unit, '
          'or renumber one of them.';
    }
    return 'Unit number $unitNumber is already used by another unit$where. '
        'Units with a repeated number must have an area. Nothing was saved. '
        'Enter an area for this unit, or use a different number.';
  }

  @override
  String toString() => message;
}

/// Turning off "Unit numbers repeat across areas" while two live units
/// share a number: the facility would go back to one unit per number with
/// two units a tenant's number could mean.
class RepeatedUnitNumbersException implements UserFacingException {
  const RepeatedUnitNumbersException(this.unitNumbers);

  /// Each number more than one live unit has, as one of them spells it.
  final List<String> unitNumbers;

  @override
  String get message {
    const shown = 10;
    final list = unitNumbers.take(shown).join(', ');
    final more = unitNumbers.length > shown
        ? ' and ${unitNumbers.length - shown} more'
        : '';
    final plural = unitNumbers.length == 1;
    return '"Unit numbers repeat across areas" can only be turned off when '
        'every unit number is used once. '
        '${plural ? 'Unit number $list is' : 'Unit numbers $list$more are'} '
        'used by more than one unit. Nothing was saved. Renumber those units '
        '(Units > unit > Edit), then turn this off.';
  }

  @override
  String toString() => message;
}

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
    String? area,
  }) async {
    try {
      final user = _auth.currentUser;
      if (user == null) {
        throw Exception('Not signed in');
      }
      final areaValue = _areaValue(area);

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

      // Check if unit number already exists in facility (or, where numbers
      // repeat across areas, in this unit's area), trimmed and ignoring
      // case (archived units included, as before). Through
      // FacilitySubcollections, like the reads, so tests run this write.
      final unitsRef = FacilitySubcollections.units(facilityId);
      final conflict =
          await unitNumberWriteConflict(facilityId, unitNumber, area: areaValue);
      if (conflict != null) throw conflict;

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
        if (areaValue != null) 'area': areaValue,
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
    String? area,
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
      // A blank area removes it; null leaves it as it is.
      if (area != null) {
        updateData['area'] = _areaValue(area) ?? FieldValue.delete();
      }
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

      // A new number: refused when another live unit has it, and the tenant
      // in the unit keeps pointing at it. Renamed alone, the tenant's
      // unitNumber named no unit, and their next edit made one.
      final beforeNumber = beforeData?['unitNumber']?.toString() ?? '';
      final newNumber = unitNumber?.trim() ?? '';
      final renaming = beforeData != null &&
          newNumber.isNotEmpty &&
          newNumber != beforeNumber.trim();
      // A new area matters where numbers repeat across areas: the number is
      // then unique per area, and a repeated number needs one.
      final beforeArea = normalizeUnitArea(beforeData?['area']);
      final areaAfter = area == null ? beforeArea : _areaValue(area);
      final areaChanging = beforeData != null &&
          area != null &&
          (areaAfter?.toLowerCase() != beforeArea?.toLowerCase());
      if (renaming || areaChanging) {
        final conflict = await unitNumberWriteConflict(
          facilityId,
          renaming ? newNumber : beforeNumber,
          area: areaAfter,
          exceptUnitId: unitId,
          includeArchived: false,
          // Only a rename is checked where numbers are unique facility-wide.
          checkNumberWhenNotRepeating: renaming,
          clearingArea: !renaming && areaChanging && areaAfter == null,
        );
        if (conflict != null) throw conflict;
      }
      // A new number or area reaches the tenant whose primary unit this is
      // (their unitNumber and unitArea), in the same transaction.
      if (renaming || area != null) {
        await _updateWithTenants(
          facilityId,
          unitRef,
          updateData,
          renamedTo: renaming ? newNumber : null,
        );
      } else {
        await unitRef.update(updateData);
      }

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

  /// Whether [facilityData] (a facility doc) has "Unit numbers repeat
  /// across areas" on: only an exact true, as FacilityModel reads it.
  static bool repeatsUnitNumbersAcrossAreas(Map<String, dynamic>? facilityData) =>
      facilityData?['unitNumbersRepeatAcrossAreas'] == true;

  /// Why a unit of [facilityId] (other than [exceptUnitId]) cannot be
  /// numbered [unitNumber] in [area]; null when it can. Reads the facility's
  /// setting and every unit ([unitNumberConflict] has the rule). Reads the
  /// whole collection: Firestore cannot match ignoring case.
  static Future<UserFacingException?> unitNumberWriteConflict(
    String facilityId,
    String unitNumber, {
    String? area,
    String? exceptUnitId,
    bool includeArchived = true,
    bool checkNumberWhenNotRepeating = true,
    bool clearingArea = false,
  }) async {
    if (unitNumberKey(unitNumber).isEmpty) return null;
    final repeat = repeatsUnitNumbersAcrossAreas(
        await FacilitySubcollections.facilityData(facilityId));
    if (!repeat && !checkNumberWhenNotRepeating) return null;
    final snap = await FacilitySubcollections.units(facilityId)
        .limit(facilityUnitReadLimit)
        .get();
    FacilitySubcollections.reportIfReadLimitReached(
        facilityId, 'unit', snap.docs.length);
    return unitNumberConflict(
      [for (final d in snap.docs) (d.id, d.data())],
      unitNumber: unitNumber,
      area: area,
      repeatAcrossAreas: repeat,
      exceptUnitId: exceptUnitId,
      includeArchived: includeArchived,
      clearingArea: clearingArea,
    );
  }

  /// The unit-number rule, for a unit (other than [exceptUnitId]) numbered
  /// [unitNumber] in [area] among [units] (id and doc data). Numbers and
  /// areas compare trimmed and ignoring case.
  ///
  /// [repeatAcrossAreas] off (every facility unless its owner turns it on):
  /// one unit per number across the facility, as before. On: one unit per
  /// number within an area, and a number more than one live unit has needs
  /// an area on each of them, so nothing names two units alike.
  /// [includeArchived]: an archived unit keeps its number (and area) against
  /// a new unit, as createUnit always did; a rename or area change only
  /// looks at live units. [clearingArea] words the refusal for an area being
  /// removed.
  @visibleForTesting
  static UserFacingException? unitNumberConflict(
    Iterable<(String, Map<String, dynamic>)> units, {
    required String unitNumber,
    required String? area,
    required bool repeatAcrossAreas,
    String? exceptUnitId,
    bool includeArchived = true,
    bool clearingArea = false,
  }) {
    final key = unitNumberKey(unitNumber);
    if (key.isEmpty) return null;
    final typed = unitNumber.trim();
    final areaName = normalizeUnitArea(area);
    final areaKey = areaName?.toLowerCase();
    DuplicateUnitNumberException duplicate(
            Map<String, dynamic> data, String number) =>
        DuplicateUnitNumberException(
          unitNumber: typed,
          existingNumber: number,
          archived: data['archived'] == true || data['isActive'] == false,
          area: repeatAcrossAreas ? areaName : null,
        );

    final sameNumber = <(Map<String, dynamic>, String)>[];
    for (final (id, data) in units) {
      if (id == exceptUnitId) continue;
      final archived = data['archived'] == true;
      if (archived && !includeArchived) continue;
      final number = data['unitNumber']?.toString() ?? '';
      if (unitNumberKey(number) == key) sameNumber.add((data, number));
    }
    if (sameNumber.isEmpty) return null;
    if (!repeatAcrossAreas) {
      final (data, number) = sameNumber.first;
      return duplicate(data, number);
    }

    bool live(Map<String, dynamic> data) => data['archived'] != true;
    String? areaOf(Map<String, dynamic> data) => normalizeUnitArea(data['area']);

    if (areaName == null) {
      // No area here: refused beside any live unit with the number, and
      // beside an archived one that has no area either (the same key).
      for (final (data, _) in sameNumber) {
        if (live(data)) {
          return UnitNumberNeedsAreaException(
            unitNumber: typed,
            otherArea: areaOf(data),
            clearingArea: clearingArea,
          );
        }
      }
      for (final (data, number) in sameNumber) {
        if (areaOf(data) == null) return duplicate(data, number);
      }
      return null;
    }
    for (final (data, _) in sameNumber) {
      if (live(data) && areaOf(data) == null) {
        return UnitNumberNeedsAreaException(
            unitNumber: typed, otherUnitHasNoArea: true);
      }
    }
    for (final (data, number) in sameNumber) {
      if (areaOf(data)?.toLowerCase() == areaKey) return duplicate(data, number);
    }
    return null;
  }

  /// The numbers more than one live (non-archived) unit has, trimmed and
  /// ignoring case, each as the first unit read spells it, sorted.
  @visibleForTesting
  static List<String> repeatedLiveUnitNumbers(
      Iterable<Map<String, dynamic>> units) {
    final seen = <String, String>{};
    final repeated = <String, String>{};
    for (final data in units) {
      if (data['archived'] == true) continue;
      final number = data['unitNumber']?.toString().trim() ?? '';
      final key = unitNumberKey(number);
      if (key.isEmpty) continue;
      final first = seen[key];
      if (first == null) {
        seen[key] = number;
      } else {
        repeated.putIfAbsent(key, () => first);
      }
    }
    return repeated.values.toList()
      ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
  }

  /// Refuses turning "Unit numbers repeat across areas" off for
  /// [facilityId] while two live units share a number
  /// ([RepeatedUnitNumbersException]).
  static Future<void> checkCanStopRepeatingUnitNumbers(String facilityId) async {
    final snap = await FacilitySubcollections.units(facilityId)
        .limit(facilityUnitReadLimit)
        .get();
    FacilitySubcollections.reportIfReadLimitReached(
        facilityId, 'unit', snap.docs.length);
    final repeated = repeatedLiveUnitNumbers([for (final d in snap.docs) d.data()]);
    if (repeated.isNotEmpty) throw RepeatedUnitNumbersException(repeated);
  }

  /// Most tenant docs [_updateWithTenants] looks at by `unitId`: a unit is
  /// one tenant's primary unit, so more than one is left from bad data.
  static const int _tenantsByUnitIdLimit = 20;

  /// Writes [updateData] to the unit and, in the same transaction, keeps the
  /// tenants whose primary unit it is in step ([tenantFieldsForUnitChange]):
  /// their unitNumber when [renamedTo] renames it, and their unitId and
  /// unitArea. Those tenants are the ones naming the unit by `unitId`, and
  /// the tenant in the unit once this update lands (one it assigns, or the
  /// one already there unless it frees the unit).
  static Future<void> _updateWithTenants(
    String facilityId,
    DocumentReference<Map<String, dynamic>> unitRef,
    Map<String, dynamic> updateData, {
    String? renamedTo,
  }) async {
    final tenants = FacilitySubcollections.tenants(facilityId);
    // Queries can't run in a client transaction: found here, re-read in it.
    final byId = await tenants
        .where('unitId', isEqualTo: unitRef.id)
        .limit(_tenantsByUnitIdLimit)
        .get();
    return unitRef.firestore.runTransaction<void>((txn) async {
      final unit = (await txn.get(unitRef)).data();
      final assigned = updateData['tenantId'];
      Object? holder;
      if (assigned is String) {
        holder = assigned;
      } else if (assigned == null) {
        holder = unit?['tenantId'];
      }
      final holderId = holder is String ? holder.trim() : '';
      final ids = <String>{
        if (holderId.isNotEmpty) holderId,
        for (final d in byId.docs) d.id,
      };
      final read = <String, Map<String, dynamic>>{};
      for (final id in ids) {
        final data = (await txn.get(tenants.doc(id))).data();
        if (data != null) read[id] = data;
      }
      final areaAfter = updateData.containsKey('area')
          ? normalizeUnitArea(updateData['area'])
          : normalizeUnitArea(unit?['area']);
      txn.update(unitRef, updateData);
      for (final e in read.entries) {
        final fields = tenantFieldsForUnitChange(
          unitId: unitRef.id,
          tenant: e.value,
          isHolder: e.key == holderId,
          numberBefore: unit?['unitNumber']?.toString() ?? '',
          renamedTo: renamedTo,
          areaAfter: areaAfter,
        );
        if (fields == null) continue;
        txn.update(tenants.doc(e.key), {
          ...fields,
          'updatedAt': FieldValue.serverTimestamp(),
        });
      }
    });
  }

  /// What a tenant doc [tenant] gets when unit [unitId] (numbered
  /// [numberBefore]) is renamed to [renamedTo] or its area becomes
  /// [areaAfter]; null for a tenant it is not the primary unit of.
  ///
  /// It is theirs when their `unitId` names it, or, for a tenant with no
  /// `unitId`, when they are in it ([isHolder]) and their unitNumber names it
  /// (trimmed, ignoring case). A tenant whose `unitId` names another unit
  /// (one of two units they hold with the same number) is left alone: that
  /// other unit is their primary one. A rename renames the unitNumber of the
  /// tenant it is the primary unit of when it named the old number, as
  /// before. Either way the unit becomes their `unitId` and its area their
  /// `unitArea`.
  @visibleForTesting
  static Map<String, dynamic>? tenantFieldsForUnitChange({
    required String unitId,
    required Map<String, dynamic> tenant,
    required bool isHolder,
    required String numberBefore,
    String? renamedTo,
    required String? areaAfter,
  }) {
    final namedId = TenantModel.textField(tenant['unitId']);
    final pointsHere = namedId == unitId;
    final label = tenant['unitNumber'];
    final labelNamesUnit = label is String &&
        label.trim().isNotEmpty &&
        sameUnitNumber(label, numberBefore);
    final ours = pointsHere || (isHolder && namedId == null && labelNamesUnit);
    if (!ours) return null;
    final renamesLabel = renamedTo != null && labelNamesUnit;
    return {
      if (renamesLabel) 'unitNumber': renamedTo,
      ...TenantModel.primaryUnitUpdate(unitId: unitId, unitArea: areaAfter),
    };
  }

  /// [area] trimmed, or null when blank. Throws when longer than
  /// [unitAreaMaxLength], which the editor and "Set area" already stop.
  static String? _areaValue(String? area) {
    final trimmed = area?.trim() ?? '';
    if (trimmed.isEmpty) return null;
    if (trimmed.length > unitAreaMaxLength) {
      throw Exception(
          'Area names can be at most $unitAreaMaxLength characters.');
    }
    return trimmed;
  }

  /// Sets one unit's area (Units > select units > Set area), or removes it
  /// when [area] is blank. Writes only `area` and the update stamp to the
  /// unit, and in the same transaction the area to the tenant whose primary
  /// unit it is (`unitArea`, [_updateWithTenants]). The area is not on the
  /// public website, so no inventory sync.
  static Future<void> setUnitArea({
    required String facilityId,
    required String unitId,
    required String? area,
  }) async {
    final user = _auth.currentUser;
    if (user == null) {
      throw Exception('Not signed in');
    }
    final areaValue = _areaValue(area);
    final unitRef = FacilitySubcollections.units(facilityId).doc(unitId);
    // Where numbers repeat across areas, a new area must not give two units
    // one number in one area, or leave a repeated number without an area.
    final before = (await unitRef.get()).data();
    final number = before?['unitNumber']?.toString() ?? '';
    final beforeArea = normalizeUnitArea(before?['area']);
    if (before != null &&
        areaValue?.toLowerCase() != beforeArea?.toLowerCase()) {
      final conflict = await unitNumberWriteConflict(
        facilityId,
        number,
        area: areaValue,
        exceptUnitId: unitId,
        includeArchived: false,
        checkNumberWhenNotRepeating: false,
        clearingArea: areaValue == null,
      );
      if (conflict != null) throw conflict;
    }
    await _updateWithTenants(
      facilityId,
      unitRef,
      {
        'area': areaValue ?? FieldValue.delete(),
        'updatedAt': FieldValue.serverTimestamp(),
        'updatedBy': user.uid,
      },
    );
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