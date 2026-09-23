import 'dart:math' as math;

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:sfcapp/models/invoice_model.dart';
import 'package:sfcapp/models/ledger_entry_model.dart';
import 'package:sfcapp/models/lien_model.dart';
import 'package:sfcapp/models/payment_model.dart';
import '../models/tenant_model.dart';
import '../models/unit_model.dart';
import 'audit_service.dart';
import 'facility_creator_account_service.dart';
import 'facility_limits_service.dart';
import 'facility_stats_service.dart';
import 'facility_service.dart';
import 'superadmin_service.dart';
import 'unit_service.dart';

/// One tenant a permanent delete was refused for, and why.
class TenantDeleteBlock {
  const TenantDeleteBlock({
    required this.tenantId,
    required this.tenantName,
    required this.reasons,
    this.heldUnitNumbers = const [],
  });

  final String tenantId;
  final String tenantName;

  /// Readable reasons, from [TenantService.permanentDeleteBlockers].
  final List<String> reasons;

  /// Units that still show this tenant as the occupant.
  final List<String> heldUnitNumbers;

  /// Archive is only a safe way out for someone who holds no unit: archiving
  /// an occupant silently stops their rent, autopay and lockout.
  bool get canArchiveInstead => heldUnitNumbers.isEmpty;
}

/// Permanent delete refused: the tenant has billing or legal history. Deleting
/// them orphaned those records, so their balance fell out of AR and their
/// ledger could no longer be opened.
class TenantHasFinancialRecordsException implements Exception {
  const TenantHasFinancialRecordsException(this.blocked);

  final List<TenantDeleteBlock> blocked;

  Map<String, List<String>> get blockersByTenantName => {
        for (final b in blocked) b.tenantName: b.reasons,
      };

  String get message {
    if (blocked.length == 1) {
      final b = blocked.single;
      return 'Nothing was deleted. ${b.tenantName} has '
          '${TenantService.joinReadable(b.reasons)}, so their history has to be kept.';
    }
    final names = blocked
        .map((b) => '${b.tenantName} (${b.reasons.join(', ')})')
        .join('; ');
    return 'Nothing was deleted. ${blocked.length} of the selected tenants have '
        'billing records that have to be kept: $names.';
  }

  /// Dialog body: what each tenant has and what to do instead. Archive is
  /// only suggested for tenants who hold no unit.
  String get details {
    String unassignFirst(TenantDeleteBlock b) => TenantStillAssignedToUnitException(
          tenantName: b.tenantName,
          unitNumbers: b.heldUnitNumbers,
        ).message;

    if (blocked.length == 1) {
      final b = blocked.single;
      final next = b.canArchiveInstead
          ? 'You can archive ${b.tenantName} instead: they leave your active '
              'lists and their history is kept.'
          : unassignFirst(b);
      return '${b.tenantName} has ${TenantService.joinReadable(b.reasons)}. '
          'Permanently deleting them would orphan that history, so it has to '
          'be kept.\n\n$next';
    }

    final lines = [
      'Nothing was deleted. These tenants have history that has to be kept:',
      for (final b in blocked)
        '• ${b.tenantName}: ${TenantService.joinReadable(b.reasons)}.'
            '${b.canArchiveInstead ? '' : ' ${unassignFirst(b)}'}',
    ];
    final archivable = blocked.where((b) => b.canArchiveInstead).length;
    if (archivable > 0) {
      lines.add('\nYou can archive the $archivable '
          '${archivable == 1 ? 'tenant who holds' : 'tenants who hold'} no unit '
          'instead; their history is kept.');
    }
    return lines.join('\n');
  }

  @override
  String toString() => message;
}

/// The pre-delete check could not read a tenant's records. An unreadable
/// history is not an empty one, so this refuses the delete.
class TenantDeleteCheckFailedException implements Exception {
  const TenantDeleteCheckFailedException(this.cause);

  final Object cause;

  String get message =>
      "Couldn't verify this tenant's billing records; nothing was deleted. "
      '${cause.toString().contains('permission-denied') ? 'Your role cannot read them; ask the facility owner.' : 'Check your connection and try again.'}';

  @override
  String toString() => message;
}

/// Archive (or switching a tenant to inactive) refused while a unit still
/// shows them as the occupant.
class TenantStillAssignedToUnitException implements Exception {
  const TenantStillAssignedToUnitException({
    required this.tenantName,
    required this.unitNumbers,
  });

  final String tenantName;
  final List<String> unitNumbers;

  String get message {
    final units = unitNumbers.length == 1
        ? 'unit ${unitNumbers.single}'
        : 'units ${unitNumbers.join(', ')}';
    return '$tenantName is still assigned to $units. Unassign the unit first '
        '(Units > unit > Unassign Tenant), then archive. Archiving someone who '
        'still holds a unit would stop their rent, autopay and lockout.';
  }

  @override
  String toString() => message;
}

/// What permanently deleting one tenant would do, read before any write.
class TenantDeletePlan {
  const TenantDeletePlan({
    required this.tenantId,
    required this.tenantName,
    required this.blockers,
    this.before,
    this.unitIds = const [],
    this.heldUnitNumbers = const [],
    this.activeGateAccessIds = const [],
  });

  final String tenantId;
  final String tenantName;
  final List<String> blockers;
  final Map<String, dynamic>? before;

  /// Every unit still linked to the tenant; the delete unlinks them all.
  final List<String> unitIds;

  /// The linked units the tenant actually occupies (for the refusal dialog).
  final List<String> heldUnitNumbers;
  final List<String> activeGateAccessIds;

  TenantDeleteBlock toBlock() => TenantDeleteBlock(
        tenantId: tenantId,
        tenantName: tenantName,
        reasons: blockers,
        heldUnitNumbers: heldUnitNumbers,
      );
}

class TenantService {
  static final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  static final FirebaseAuth _auth = FirebaseAuth.instance;

  // Create a new tenant
  static Future<String> createTenant({
    required String facilityId,
    required String name,
    required String email,
    required String phone,
    required String unitNumber,
    required double monthlyRate,
    String? notes,
    DateTime? moveInDate,
    String? governmentIdType,
    String? governmentIdNumber,
    String? governmentIdState,
    String? governmentIdCountry,
    DateTime? governmentIdIssuedAt,
    DateTime? governmentIdExpiresAt,
    List<TenantContact>? emergencyContacts,
    List<TenantVehicle>? vehicles,
    bool portalEnabled = false,
    String? portalAccessCode,
    String? portalWelcomeMessage,
    String? leadSource,
    DateTime? smsOptInDate,
  }) async {
    try {
      final user = _auth.currentUser;
      if (user == null) {
        throw Exception('Not signed in');
      }

      // Check facility tenant limit (hard cap: 250)
      final canAdd = await FacilityLimitsService.canAddTenant(facilityId);
      if (!canAdd) {
        final currentCount = await FacilityLimitsService.getTenantCount(facilityId);
        throw Exception(
          'Tenant limit reached. This facility has reached the maximum of ${FacilityLimitsService.maxTenantsPerFacility} tenants. '
          'Current count: $currentCount. Please contact support if you need to increase your limit.'
        );
      }

      if (kDebugMode) {
        print('🔄 Creating tenant: $name in facility: $facilityId');
        print('🔄 User UID: ${user.uid}');
      }

      // Create a simple document with minimal fields first
      final ref = _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('tenants')
          .doc();

      final tenantData = {
        'facilityId': facilityId,
        'name': name,
        'nameLower': name.toLowerCase(),  // For search
        'email': email,
        'emailLower': email.toLowerCase(),  // For search
        'phone': phone,
        'phoneDigits': phone.replaceAll(RegExp(r'[^\d]'), ''),  // For search
        'unitNumber': unitNumber,
        'monthlyRate': monthlyRate,
        'notes': notes ?? '',
        'createdAt': FieldValue.serverTimestamp(),
        'createdBy': user.uid,  // ✅ REQUIRED for security rules
        'isActive': true,
        'isOnDNR': false,
        if (governmentIdType != null && governmentIdType.isNotEmpty) 'governmentIdType': governmentIdType,
        if (governmentIdNumber != null && governmentIdNumber.isNotEmpty) 'governmentIdNumber': governmentIdNumber,
        if (governmentIdState != null && governmentIdState.isNotEmpty) 'governmentIdState': governmentIdState,
        if (governmentIdCountry != null && governmentIdCountry.isNotEmpty) 'governmentIdCountry': governmentIdCountry,
        if (governmentIdIssuedAt != null) 'governmentIdIssuedAt': Timestamp.fromDate(governmentIdIssuedAt),
        if (governmentIdExpiresAt != null) 'governmentIdExpiresAt': Timestamp.fromDate(governmentIdExpiresAt),
        'emergencyContacts': (emergencyContacts ?? const <TenantContact>[]).map((contact) => contact.toMap()).toList(),
        'vehicles': (vehicles ?? const <TenantVehicle>[]).map((vehicle) => vehicle.toMap()).toList(),
        'portalEnabled': portalEnabled,
        'portalAccessCode': portalEnabled ? portalAccessCode : null,
        'portalWelcomeMessage': portalWelcomeMessage,
        'portalLastAccessAt': null,
        'portalVisitCount': 0,
        if (leadSource != null && leadSource.isNotEmpty) 'leadSource': leadSource,
        'smsOptOut': false,
        if (smsOptInDate != null) 'smsOptInDate': Timestamp.fromDate(smsOptInDate),
      };

      if (kDebugMode) {
        print('🔄 Setting tenant data: $tenantData');
      }

      await ref.set(tenantData);

      // Log audit event
      await AuditService.logEvent(
        facilityId: facilityId,
        eventType: 'tenant.created',
        targetType: 'tenant',
        targetId: ref.id,
        tenantId: ref.id,
        after: {
          'name': name,
          'email': email,
          'phone': phone,
          'unitNumber': unitNumber,
          'monthlyRate': monthlyRate,
        },
        metadata: {
          'leadSource': leadSource,
          'portalEnabled': portalEnabled,
        },
      );

      // Update unit status to occupied if unitNumber is provided
      // If unit doesn't exist, create it automatically
      if (unitNumber.isNotEmpty) {
        await _updateUnitOccupancy(facilityId, unitNumber, ref.id, name, true, monthlyRate);
      }

      if (kDebugMode) {
        print('✅ Tenant created successfully: ${ref.id}');
      }

      return ref.id;
    } catch (e) {
      if (kDebugMode) {
        print('❌ Error creating tenant: $e');
        if (e.toString().contains('permission-denied')) {
          print('🚨 PERMISSION DENIED: Check Firestore security rules for tenants');
        }
      }
      rethrow;
    }
  }

  // Get all tenants for a facility (real-time stream)
  static Stream<List<TenantModel>> getTenantsForFacilityStream(String facilityId) {
    try {
      final user = _auth.currentUser;
      if (user == null) {
        throw Exception('Not signed in');
      }

      if (kDebugMode) {
        print('🔄 Setting up tenants stream for facility: $facilityId');
      }

      Query query = _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('tenants')
          .limit(250); // Hard cap: 250 tenants per facility
      
      // Try ordered query, fall back to unordered if index is building
      try {
        query = query.orderBy('name');
      } catch (orderingError) {
        if (kDebugMode) {
          print('⚠️ Ordered query not available, using unordered: $orderingError');
        }
      }

      return query.snapshots().map((snapshot) {
        final tenants = snapshot.docs.map((doc) {
          return TenantModel.fromFirestore(doc);
        }).toList();

        // Sort in memory if we used fallback query
        tenants.sort((a, b) => a.name.compareTo(b.name));

        if (kDebugMode) {
          print('📡 Stream update: ${tenants.length} tenants for facility: $facilityId');
        }

        return tenants;
      });
    } catch (e) {
      if (kDebugMode) {
        print('❌ Error setting up tenants stream: $e');
      }
      rethrow;
    }
  }

  // Get active tenants for a facility (real-time stream)
  static Stream<List<TenantModel>> getActiveTenantsForFacilityStream(String facilityId) {
    try {
      final user = _auth.currentUser;
      if (user == null) {
        throw Exception('Not signed in');
      }

      if (kDebugMode) {
        print('🔄 Setting up active tenants stream for facility: $facilityId');
      }

      Query query = _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('tenants')
          .where('isActive', isEqualTo: true)
          .limit(250); // Hard cap: 250 tenants per facility
      
      // Try ordered query, fall back to unordered if index is building
      try {
        query = query.orderBy('name');
      } catch (orderingError) {
        if (kDebugMode) {
          print('⚠️ Ordered query not available, using unordered: $orderingError');
        }
      }

      return query.snapshots().map((snapshot) {
        final tenants = snapshot.docs.map((doc) {
          return TenantModel.fromFirestore(doc);
        }).toList();

        // Sort in memory if we used fallback query
        tenants.sort((a, b) => a.name.compareTo(b.name));

        if (kDebugMode) {
          print('📡 Stream update: ${tenants.length} active tenants for facility: $facilityId');
        }

        return tenants;
      });
    } catch (e) {
      if (kDebugMode) {
        print('❌ Error setting up active tenants stream: $e');
      }
      rethrow;
    }
  }

  // Get all tenants for a facility
  static Future<List<TenantModel>> getTenantsForFacility(String facilityId) async {
    try {
      final user = _auth.currentUser;
      if (user == null) {
        throw Exception('Not signed in');
      }

      if (kDebugMode) {
        print('🔄 Getting tenants for facility: $facilityId');
      }

      // Try ordered query first, fall back to unordered if index is building
      QuerySnapshot snapshot;
      try {
        snapshot = await _firestore
            .collection('facilities')
            .doc(facilityId)
            .collection('tenants')
            .orderBy('name')
            .limit(250) // Hard cap: 250 tenants per facility
            .get();
      } catch (orderingError) {
        if (orderingError.toString().contains('failed-precondition') && orderingError.toString().contains('index')) {
          if (kDebugMode) {
            print('📋 INDEX BUILDING: Using fallback unordered query for tenants...');
          }
          // Fallback to unordered query
          snapshot = await _firestore
              .collection('facilities')
              .doc(facilityId)
              .collection('tenants')
              .limit(250) // Hard cap: 250 tenants per facility
              .get();
        } else {
          rethrow;
        }
      }

      if (kDebugMode) {
        print('✅ Successfully retrieved ${snapshot.docs.length} tenants');
      }

      final tenants = snapshot.docs
          .map((doc) => TenantModel.fromFirestore(doc))
          .toList();
          
      // Sort in memory (needed for fallback queries)
      tenants.sort((a, b) => a.name.compareTo(b.name));
      
      return tenants;
    } catch (e) {
      if (kDebugMode) {
        print('❌ Error getting tenants: $e');
      }
      return [];
    }
  }

  // Get all tenants across all facilities for the current user
  static Future<List<TenantModel>> getAllTenants() async {
    try {
      final user = _auth.currentUser;
      if (user == null) {
        throw Exception('Not signed in');
      }

      if (kDebugMode) {
        print('🔄 Getting all tenants for user: ${user.uid}');
      }

      // First get all facilities owned by the user
      final facilitiesSnapshot = await _firestore
          .collection('facilities')
          .where('ownerUid', isEqualTo: user.uid)
          .get();

      if (facilitiesSnapshot.docs.isEmpty) {
        return [];
      }

      // Get tenants from all facilities
      final List<TenantModel> allTenants = [];
      
      for (final facilityDoc in facilitiesSnapshot.docs) {
        final tenantsSnapshot = await _firestore
            .collection('facilities')
            .doc(facilityDoc.id)
            .collection('tenants')
            .limit(250) // Hard cap: 250 tenants per facility
            .get();

        allTenants.addAll(
          tenantsSnapshot.docs.map((doc) => TenantModel.fromFirestore(doc)),
        );
      }

      // Sort by name
      allTenants.sort((a, b) => a.name.compareTo(b.name));

      if (kDebugMode) {
        print('✅ Successfully retrieved ${allTenants.length} tenants across all facilities');
      }

      return allTenants;
    } catch (e) {
      if (kDebugMode) {
        print('❌ Error getting all tenants: $e');
      }
      return [];
    }
  }

  // Update tenant
  static Future<void> updateTenant({
    required String facilityId,
    required String tenantId,
    String? name,
    String? email,
    String? phone,
    String? unitNumber,
    double? monthlyRate,
    DateTime? paidThrough, // NEW: Allow updating paid through date
    bool clearPaidThrough = false, // NEW: Allow clearing paid through date
    String? notes,
    bool? isActive,
    String? governmentIdType,
    String? governmentIdNumber,
    String? governmentIdState,
    String? governmentIdCountry,
    DateTime? governmentIdIssuedAt,
    DateTime? governmentIdExpiresAt,
    bool clearGovernmentIdIssuedAt = false,
    bool clearGovernmentIdExpiresAt = false,
    List<TenantContact>? emergencyContacts,
    List<TenantVehicle>? vehicles,
    bool? portalEnabled,
    String? portalAccessCode,
    bool clearPortalAccessCode = false,
    String? portalWelcomeMessage,
    DateTime? portalLastAccessAt,
    bool resetPortalStats = false,
    InsuranceStatus? insuranceStatus,
    String? insuranceProvider,
    String? insuranceProofUrl,
    bool clearInsuranceProofUrl = false,
    double? coverageAmount,
    DateTime? tppEnrollmentDate,
    String? tppCoverageLevel,
    DateTime? smsOptInDate,
    Map<String, String>? monthStatusOverrides,
  }) async {
    try {
      final user = _auth.currentUser;
      if (user == null) {
        throw Exception('Not signed in');
      }

      if (kDebugMode) {
        print('🔄 Updating tenant: $tenantId');
      }

      final updateData = <String, dynamic>{
        'updatedAt': FieldValue.serverTimestamp(),
      };

      if (name != null) {
        updateData['name'] = name;
        updateData['nameLower'] = name.toLowerCase();
      }
      if (email != null) {
        updateData['email'] = email;
        updateData['emailLower'] = email.toLowerCase();
      }
      if (phone != null) {
        updateData['phone'] = phone;
        updateData['phoneDigits'] = phone.replaceAll(RegExp(r'[^\d]'), '');
      }
      if (unitNumber != null) updateData['unitNumber'] = unitNumber;
      if (monthlyRate != null) {
        updateData['monthlyRate'] = monthlyRate;
      }
      if (paidThrough != null) {
        updateData['paidThrough'] = Timestamp.fromDate(paidThrough);
      } else if (clearPaidThrough) {
        updateData['paidThrough'] = FieldValue.delete();
      }
      if (notes != null) updateData['notes'] = notes;
      if (isActive != null) updateData['isActive'] = isActive;
      if (governmentIdType != null) {
        updateData['governmentIdType'] = governmentIdType.isEmpty ? FieldValue.delete() : governmentIdType;
      }
      if (governmentIdNumber != null) {
        updateData['governmentIdNumber'] = governmentIdNumber.isEmpty ? FieldValue.delete() : governmentIdNumber;
      }
      if (governmentIdState != null) {
        updateData['governmentIdState'] = governmentIdState.isEmpty ? FieldValue.delete() : governmentIdState;
      }
      if (governmentIdCountry != null) {
        updateData['governmentIdCountry'] = governmentIdCountry.isEmpty ? FieldValue.delete() : governmentIdCountry;
      }
      if (governmentIdIssuedAt != null) {
        updateData['governmentIdIssuedAt'] = Timestamp.fromDate(governmentIdIssuedAt);
      } else if (clearGovernmentIdIssuedAt) {
        updateData['governmentIdIssuedAt'] = FieldValue.delete();
      }
      if (governmentIdExpiresAt != null) {
        updateData['governmentIdExpiresAt'] = Timestamp.fromDate(governmentIdExpiresAt);
      } else if (clearGovernmentIdExpiresAt) {
        updateData['governmentIdExpiresAt'] = FieldValue.delete();
      }
      if (emergencyContacts != null) {
        updateData['emergencyContacts'] = emergencyContacts.map((contact) => contact.toMap()).toList();
      }
      if (vehicles != null) {
        updateData['vehicles'] = vehicles.map((vehicle) => vehicle.toMap()).toList();
      }
      if (portalEnabled != null) {
        updateData['portalEnabled'] = portalEnabled;
        if (!portalEnabled) {
          updateData['portalAccessCode'] = null;
        }
      }
      if (portalAccessCode != null) {
        updateData['portalAccessCode'] = portalAccessCode.isEmpty ? null : portalAccessCode;
      } else if (clearPortalAccessCode) {
        updateData['portalAccessCode'] = null;
      }
      if (portalWelcomeMessage != null) {
        updateData['portalWelcomeMessage'] =
            portalWelcomeMessage.isEmpty ? FieldValue.delete() : portalWelcomeMessage;
      }
      if (portalLastAccessAt != null) {
        updateData['portalLastAccessAt'] = Timestamp.fromDate(portalLastAccessAt);
      }
      if (resetPortalStats) {
        updateData['portalVisitCount'] = 0;
      }
      if (insuranceStatus != null) {
        updateData['insuranceStatus'] = insuranceStatus.name;
      }
      if (insuranceProvider != null) {
        updateData['insuranceProvider'] = insuranceProvider.isEmpty ? FieldValue.delete() : insuranceProvider;
      }
      if (insuranceProofUrl != null) {
        updateData['insuranceProofUrl'] = insuranceProofUrl.isEmpty ? FieldValue.delete() : insuranceProofUrl;
      }
      if (clearInsuranceProofUrl) {
        updateData['insuranceProofUrl'] = FieldValue.delete();
      }
      if (coverageAmount != null) {
        updateData['coverageAmount'] = coverageAmount;
      }
      if (tppEnrollmentDate != null) {
        updateData['tppEnrollmentDate'] = Timestamp.fromDate(tppEnrollmentDate);
      }
      if (tppCoverageLevel != null) {
        updateData['tppCoverageLevel'] = tppCoverageLevel.isEmpty ? FieldValue.delete() : tppCoverageLevel;
      }
      if (smsOptInDate != null) {
        updateData['smsOptInDate'] = Timestamp.fromDate(smsOptInDate);
        // If opting in, clear opt-out status
        updateData['smsOptOut'] = false;
        updateData['smsOptOutDate'] = FieldValue.delete();
      }

      // Month status overrides: Map<String, String> keyed by "yyyy-MM", value "paid"|"late"|"moved_out"
      if (monthStatusOverrides != null) {
        updateData['monthStatusOverrides'] = monthStatusOverrides;
      }

      // Get before snapshot for audit log
      final beforeDoc = await _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('tenants')
          .doc(tenantId)
          .get();
      final beforeData = beforeDoc.exists ? beforeDoc.data() : null;

      final deactivating = isActive == false &&
          beforeData != null &&
          ((beforeData['isActive'] as bool?) ?? true);
      if (deactivating && unitNumber == null) {
        // This call leaves the unit link alone, so switching the tenant off
        // would stop rent, autopay and lockout on a unit that still shows
        // them as the occupant. Same rule as archive.
        await _assertHoldsNoUnits(
            facilityId, tenantId, _displayName(beforeData, tenantId));
      }

      await _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('tenants')
          .doc(tenantId)
          .update(updateData);

      if (deactivating) {
        // An inactive tenant keeps no gate code. Best effort, as move-out
        // does: the tenant update has already happened.
        try {
          await _deactivateGateAccess(facilityId, tenantId, user.uid);
        } catch (e) {
          if (kDebugMode) {
            print('⚠️ Could not deactivate gate access for $tenantId: $e');
          }
        }
      }

      // Get after snapshot for audit log
      final afterDoc = await _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('tenants')
          .doc(tenantId)
          .get();
      final afterData = afterDoc.exists ? afterDoc.data() : null;

      // Log audit event
      await AuditService.logEvent(
        facilityId: facilityId,
        eventType: 'tenant.edited',
        targetType: 'tenant',
        targetId: tenantId,
        tenantId: tenantId,
        before: beforeData != null ? Map<String, dynamic>.from(beforeData) : null,
        after: afterData != null ? Map<String, dynamic>.from(afterData) : null,
        metadata: {
          'fieldsChanged': updateData.keys.toList(),
        },
      );

      // Keep facilities/{id}/units in sync when unit number changes (createTenant already does this).
      if (unitNumber != null && beforeData != null) {
        final oldNum = (beforeData['unitNumber'] as String?)?.trim() ?? '';
        final newNum = unitNumber.trim();
        final wasActive = (beforeData['isActive'] as bool?) ?? true;
        final nowActive = isActive ?? wasActive;
        final resolvedName =
            name ?? (beforeData['name'] as String?)?.trim() ?? '';
        final resolvedRate = monthlyRate ??
            ((beforeData['monthlyRate'] as num?)?.toDouble() ?? 0.0);

        if (oldNum != newNum) {
          if (oldNum.isNotEmpty) {
            await _updateUnitOccupancy(
                facilityId, oldNum, tenantId, resolvedName, false, resolvedRate);
          }
          if (newNum.isNotEmpty && nowActive) {
            await _updateUnitOccupancy(
                facilityId, newNum, tenantId, resolvedName, true, resolvedRate);
          }
          await FacilityStatsService.updateFacilityStats(facilityId);
        } else if (newNum.isNotEmpty && isActive == false && wasActive) {
          await _updateUnitOccupancy(
              facilityId, newNum, tenantId, resolvedName, false, resolvedRate);
          await FacilityStatsService.updateFacilityStats(facilityId);
        } else if (newNum.isNotEmpty && nowActive) {
          final unitsSnap = await _firestore
              .collection('facilities')
              .doc(facilityId)
              .collection('units')
              .where('unitNumber', isEqualTo: newNum)
              .limit(5)
              .get();
          final activeDocs = unitsSnap.docs.where((d) {
            final m = d.data();
            return (m['isActive'] ?? true) == true;
          }).toList();
          if (activeDocs.isNotEmpty) {
            final m = activeDocs.first.data();
            final linked = (m['tenantId'] as String?)?.trim();
            final st = (m['status'] as String?)?.trim().toLowerCase();
            final needsHeal =
                linked != tenantId || st != UnitStatus.occupied.name;
            if (needsHeal) {
              await _updateUnitOccupancy(facilityId, newNum, tenantId,
                  resolvedName, true, resolvedRate);
              await FacilityStatsService.updateFacilityStats(facilityId);
            }
          } else {
            await _updateUnitOccupancy(
                facilityId, newNum, tenantId, resolvedName, true, resolvedRate);
            await FacilityStatsService.updateFacilityStats(facilityId);
          }
        }
      }

      if (kDebugMode) {
        print('✅ Tenant updated successfully: $tenantId');
      }
    } catch (e) {
      if (kDebugMode) {
        print('❌ Error updating tenant: $e');
      }
      rethrow;
    }
  }

  /// Update manual month status override. yearMonth: "yyyy-MM", status: "paid"|"late"|"moved_out" or null to clear.
  static Future<void> updateTenantMonthStatus({
    required String facilityId,
    required String tenantId,
    required String yearMonth,
    required String? status,
  }) async {
    try {
      final user = _auth.currentUser;
      if (user == null) throw Exception('Not signed in');

      final updateData = <String, dynamic>{
        'updatedAt': FieldValue.serverTimestamp(),
      };
      if (status != null) {
        updateData['monthStatusOverrides.$yearMonth'] = status;
      } else {
        updateData['monthStatusOverrides.$yearMonth'] = FieldValue.delete();
      }

      await _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('tenants')
          .doc(tenantId)
          .update(updateData);

      if (kDebugMode) {
        print('✅ Tenant month status updated: $tenantId $yearMonth -> $status');
      }
    } catch (e) {
      if (kDebugMode) print('❌ Error updating tenant month status: $e');
      rethrow;
    }
  }

  // Mark tenant as late by setting paidThrough to null or past date
  static Future<void> markTenantAsLate({
    required String facilityId,
    required String tenantId,
    DateTime? paidThroughDate,
  }) async {
    try {
      final user = _auth.currentUser;
      if (user == null) {
        throw Exception('Not signed in');
      }

      if (kDebugMode) {
        print('🔄 Marking tenant as late: $tenantId');
      }

      // If no date provided, set to null (makes tenant late)
      // If date provided, set to that date (e.g., past date to make late)
      final updateData = <String, dynamic>{
        'updatedAt': FieldValue.serverTimestamp(),
      };

      if (paidThroughDate == null) {
        updateData['paidThrough'] = FieldValue.delete();
      } else {
        updateData['paidThrough'] = Timestamp.fromDate(paidThroughDate);
      }

      await _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('tenants')
          .doc(tenantId)
          .update(updateData);

      if (kDebugMode) {
        print('✅ Tenant marked as late successfully: $tenantId');
      }
    } catch (e) {
      if (kDebugMode) {
        print('❌ Error marking tenant as late: $e');
      }
      rethrow;
    }
  }

  static Future<TenantModel?> getTenantById(String facilityId, String tenantId) async {
    try {
      final doc = await _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('tenants')
          .doc(tenantId)
          .get();

      if (!doc.exists) {
        return null;
      }

      return TenantModel.fromFirestore(doc);
    } catch (e) {
      if (kDebugMode) {
        print('❌ Error fetching tenant $tenantId for facility $facilityId: $e');
      }
      rethrow;
    }
  }

  // Archive tenant
  static Future<void> archiveTenant({
    required String facilityId,
    required String tenantId,
  }) async {
    try {
      final user = _auth.currentUser;
      if (user == null) {
        throw Exception('Not signed in');
      }

      if (kDebugMode) {
        print('🔄 Archiving tenant: $tenantId');
      }

      final facilityRef = _firestore.collection('facilities').doc(facilityId);
      final tenantRef = facilityRef.collection('tenants').doc(tenantId);

      // Get before snapshot for audit log
      final beforeDoc = await tenantRef.get();
      final beforeData = beforeDoc.exists ? beforeDoc.data() : null;

      // Rent, autopay and delinquency jobs skip inactive tenants, so archiving
      // someone who still holds a unit silently stopped their rent and
      // lockout while the unit kept showing as occupied.
      await _assertHoldsNoUnits(
          facilityId, tenantId, _displayName(beforeData, tenantId));

      // Archive and gate-code shutoff land together: an archived tenant kept
      // an enabled gate code before (only move-out turned it off).
      final gateAccessIds = await _activeGateAccessIds(facilityId, tenantId);
      final batch = _firestore.batch();
      batch.update(tenantRef, {
        'isActive': false,
        'updatedAt': FieldValue.serverTimestamp(),
      });
      final gateOff = _gateAccessOffFields(user.uid);
      for (final accessId in gateAccessIds) {
        batch.update(facilityRef.collection('gateAccess').doc(accessId), gateOff);
      }
      await batch.commit();

      // Log audit event
      await AuditService.logEvent(
        facilityId: facilityId,
        eventType: 'tenant.archived',
        targetType: 'tenant',
        targetId: tenantId,
        tenantId: tenantId,
        before: beforeData != null ? Map<String, dynamic>.from(beforeData) : null,
        after: {'isActive': false},
        metadata: {'gateAccessDeactivated': gateAccessIds.length},
      );

      if (kDebugMode) {
        print('✅ Tenant archived successfully: $tenantId');
      }
    } catch (e) {
      if (kDebugMode) {
        print('❌ Error archiving tenant: $e');
      }
      rethrow;
    }
  }

  /// Paid active or non-expired trial at account or per-facility platform sub. Superadmins bypass.
  static Future<void> _assertFacilityAllowsPermanentTenantDeletion(String facilityId) async {
    final user = _auth.currentUser;
    if (user == null) {
      throw Exception('Not signed in');
    }
    if (SuperAdminService.isSuperAdmin()) {
      return;
    }

    final facility = await FacilityService.getFacility(facilityId);
    if (facility == null) {
      throw Exception('Facility not found');
    }
    if (facility.hasActivePlatformSubscription) {
      return;
    }

    final accountId = facility.facilityCreatorAccountId;
    if (accountId != null && accountId.isNotEmpty) {
      final account = await FacilityCreatorAccountService.getAccount(accountId);
      if (account != null && account.allowsPermanentTenantDeletion) {
        return;
      }
    }

    throw Exception(
      'Permanent tenant deletion requires an active paid subscription or an active trial. '
      'Use archive to remove a tenant from day-to-day operations, or subscribe / start a trial to delete.',
    );
  }

  // --- Permanent delete guard -------------------------------------------
  //
  // Permanent delete is only for tenants entered by mistake. Anyone with
  // billing or legal history is refused, because deleting the tenant doc
  // orphaned their ledger, invoices and payments: the balance vanished from
  // AR and the history could no longer be opened. Archive keeps it.

  /// Rows read per collection when checking a tenant for history.
  static const int _deleteCheckScanLimit = 10;

  /// Tenants checked at once in a bulk delete (each check is ~9 queries).
  static const int _deleteCheckConcurrency = 8;

  /// Writes per batch, under Firestore's 500 cap.
  static const int _maxWritesPerBatch = 450;

  /// Posted or pending. A voided entry was reversed and leaves nothing behind.
  static bool isLiveLedgerEntry(LedgerEntry e) =>
      e.status != LedgerEntryStatus.voided;

  /// Draft, sent, paid and overdue invoices are all history; only voided is not.
  static bool isLiveInvoice(InvoiceModel i) => i.status != InvoiceStatus.voided;

  /// Failed and cancelled payments never moved money, and archived ones were
  /// removed on purpose. Everything else (pending, paid, refunded, and
  /// statuses the model reads as pending, like disputed) is real history.
  static bool isLivePayment(PaymentModel p) =>
      p.isActive &&
      p.status != PaymentStatus.failed &&
      p.status != PaymentStatus.cancelled;

  static bool isLiveLien(LienModel l) => l.isActive && l.isActiveLien;

  /// Contracts, saved cards and gate codes count as active unless switched
  /// off. A missing flag means active, as in their models.
  static bool isActiveFlagSet(Map<String, dynamic>? data) =>
      data?['isActive'] != false;

  /// How many rows of a capped scan count as live. A row that can't be read
  /// counts as live, and so does a full page with none live, because rows past
  /// the cap may be live: deleting on a guess would orphan them.
  static int liveCountFromScan<T>(
    Iterable<T> rows,
    bool Function(T row) isLive, {
    required int scanLimit,
  }) {
    var total = 0;
    var live = 0;
    for (final row in rows) {
      total++;
      bool rowIsLive;
      try {
        rowIsLive = isLive(row);
      } catch (_) {
        rowIsLive = true;
      }
      if (rowIsLive) live++;
    }
    if (live == 0 && total >= scanLimit) return 1;
    return live;
  }

  /// Readable reasons a tenant can't be permanently deleted; empty means the
  /// delete may go ahead. Gated on history, not balance: a tenant charged $150
  /// who paid $150 owes nothing but is still a real customer.
  static List<String> permanentDeleteBlockers({
    required int liveLedgerEntries,
    required int liveInvoices,
    required int livePayments,
    required int activeContracts,
    required int activeSavedCards,
    int activeLiens = 0,
  }) {
    String counted(int n, String one, String many) => n == 1 ? one : many;
    return [
      if (liveLedgerEntries > 0) 'charges or payments on the ledger',
      if (liveInvoices > 0) counted(liveInvoices, 'an invoice', 'invoices'),
      if (livePayments > 0)
        counted(livePayments, 'a payment record', 'payment records'),
      if (activeContracts > 0)
        counted(activeContracts, 'an active contract', 'active contracts'),
      if (activeSavedCards > 0)
        counted(activeSavedCards, 'a saved card', 'saved cards'),
      if (activeLiens > 0) counted(activeLiens, 'an active lien', 'active liens'),
    ];
  }

  /// Units that show [tenantId] as their occupant; any one of them rules out
  /// archiving (see [TenantDeleteBlock.canArchiveInstead]). A unit marked
  /// available with a stale link is not held, and has no Unassign button, so
  /// counting it would leave the owner unable to archive at all.
  static List<String> unitNumbersHeldByTenant(
    String tenantId,
    Iterable<UnitModel> units,
  ) {
    return units
        .where((u) => u.tenantId == tenantId && u.status != UnitStatus.available)
        .map((u) => u.unitNumber)
        .toList();
  }

  /// "a", "a and b", "a, b and c".
  static String joinReadable(List<String> parts) {
    if (parts.length <= 1) return parts.join();
    return '${parts.sublist(0, parts.length - 1).join(', ')} and ${parts.last}';
  }

  /// Runs [load] for every id, [concurrency] at a time, results in id order.
  /// Any failure refuses the whole operation: a tenant whose records could
  /// not be read must never be treated as having none.
  @visibleForTesting
  static Future<List<T>> loadAllForDelete<T>(
    List<String> tenantIds,
    Future<T> Function(String tenantId) load, {
    int concurrency = _deleteCheckConcurrency,
  }) async {
    final results = <T>[];
    try {
      for (var i = 0; i < tenantIds.length; i += concurrency) {
        final slice =
            tenantIds.sublist(i, math.min(i + concurrency, tenantIds.length));
        results.addAll(await Future.wait(slice.map(load)));
      }
    } on TenantDeleteCheckFailedException {
      rethrow;
    } catch (e) {
      throw TenantDeleteCheckFailedException(e);
    }
    return results;
  }

  /// The order that makes permanent delete safe: read every tenant first,
  /// refuse them all if any has history (the dialog said "Delete N"), and
  /// only then write. [commit] is never called on a refusal.
  @visibleForTesting
  static Future<List<TenantDeletePlan>> runPermanentDelete({
    required List<String> tenantIds,
    required Future<TenantDeletePlan> Function(String tenantId) loadPlan,
    required Future<void> Function(List<TenantDeletePlan> plans) commit,
  }) async {
    final plans = await loadAllForDelete(tenantIds, loadPlan);
    final blocked = plans
        .where((p) => p.blockers.isNotEmpty)
        .map((p) => p.toBlock())
        .toList();
    if (blocked.isNotEmpty) {
      throw TenantHasFinancialRecordsException(blocked);
    }
    await commit(plans);
    return plans;
  }

  /// Packs per-tenant write groups into batches of at most [maxPerChunk],
  /// never splitting a group that fits in one. If a later batch is refused,
  /// each tenant is then either fully deleted or untouched, never a freed
  /// unit pointing at a tenant who still exists.
  @visibleForTesting
  static List<List<T>> packWriteGroups<T>(
    List<List<T>> groups, {
    int maxPerChunk = _maxWritesPerBatch,
  }) {
    final chunks = <List<T>>[];
    var current = <T>[];
    for (final group in groups) {
      if (current.isNotEmpty && current.length + group.length > maxPerChunk) {
        chunks.add(current);
        current = <T>[];
      }
      if (group.length > maxPerChunk) {
        for (var i = 0; i < group.length; i += maxPerChunk) {
          chunks.add(group.sublist(i, math.min(i + maxPerChunk, group.length)));
        }
        continue;
      }
      current.addAll(group);
    }
    if (current.isNotEmpty) chunks.add(current);
    return chunks;
  }

  static String _displayName(Map<String, dynamic>? data, String tenantId) {
    final name = (data?['name'] as String?)?.trim() ?? '';
    return name.isEmpty ? tenantId : name;
  }

  static Map<String, dynamic> _gateAccessOffFields(String uid) {
    // Same fields GateAccessService.updateGateAccess writes; the rules want
    // updatedBy to be the caller.
    return {
      'isActive': false,
      'updatedAt': Timestamp.fromDate(DateTime.now()),
      'updatedBy': uid,
    };
  }

  /// Non-archived units linked to the tenant. Throws on a read error, so
  /// callers fail closed rather than reading "no units".
  static Future<List<QueryDocumentSnapshot<Map<String, dynamic>>>>
      _linkedUnitDocs(String facilityId, String tenantId) async {
    final snap = await _firestore
        .collection('facilities')
        .doc(facilityId)
        .collection('units')
        .where('tenantId', isEqualTo: tenantId)
        .get();
    return snap.docs.where((d) => d.data()['archived'] != true).toList();
  }

  static Future<void> _assertHoldsNoUnits(
    String facilityId,
    String tenantId,
    String tenantName,
  ) async {
    final docs = await _linkedUnitDocs(facilityId, tenantId);
    final held =
        unitNumbersHeldByTenant(tenantId, docs.map(UnitModel.fromFirestore));
    if (held.isNotEmpty) {
      throw TenantStillAssignedToUnitException(
        tenantName: tenantName,
        unitNumbers: held,
      );
    }
  }

  static Future<List<String>> _activeGateAccessIds(
    String facilityId,
    String tenantId,
  ) async {
    final snap = await _firestore
        .collection('facilities')
        .doc(facilityId)
        .collection('gateAccess')
        .where('tenantId', isEqualTo: tenantId)
        .get();
    return snap.docs
        .where((d) => isActiveFlagSet(d.data()))
        .map((d) => d.id)
        .toList();
  }

  static Future<void> _deactivateGateAccess(
    String facilityId,
    String tenantId,
    String uid,
  ) async {
    final ids = await _activeGateAccessIds(facilityId, tenantId);
    if (ids.isEmpty) return;
    final ref = _firestore
        .collection('facilities')
        .doc(facilityId)
        .collection('gateAccess');
    final batch = _firestore.batch();
    final off = _gateAccessOffFields(uid);
    for (final id in ids) {
      batch.update(ref.doc(id), off);
    }
    await batch.commit();
  }

  /// Reads everything a permanent delete of [tenantId] needs to know. Every
  /// query is equality on tenantId only, so the single-field indexes serve
  /// them and no composite index is needed.
  static Future<TenantDeletePlan> _loadDeletePlan(
    String facilityId,
    String tenantId,
  ) async {
    final facilityRef = _firestore.collection('facilities').doc(facilityId);
    final tenantRef = facilityRef.collection('tenants').doc(tenantId);
    Future<QuerySnapshot<Map<String, dynamic>>> scan(String collection) =>
        facilityRef
            .collection(collection)
            .where('tenantId', isEqualTo: tenantId)
            .limit(_deleteCheckScanLimit)
            .get();

    final results = await Future.wait<Object>([
      tenantRef.get(),
      scan('ledgers'),
      scan('invoices'),
      scan('payments'),
      scan('contracts'),
      scan('liens'),
      tenantRef.collection('paymentMethods').limit(_deleteCheckScanLimit).get(),
      _linkedUnitDocs(facilityId, tenantId),
      _activeGateAccessIds(facilityId, tenantId),
    ]);
    final tenantSnap = results[0] as DocumentSnapshot<Map<String, dynamic>>;
    List<QueryDocumentSnapshot<Map<String, dynamic>>> docs(int i) =>
        (results[i] as QuerySnapshot<Map<String, dynamic>>).docs;
    int live(
      List<QueryDocumentSnapshot<Map<String, dynamic>>> rows,
      bool Function(QueryDocumentSnapshot<Map<String, dynamic>> d) isLive,
    ) =>
        liveCountFromScan(rows, isLive, scanLimit: _deleteCheckScanLimit);

    final units =
        results[7] as List<QueryDocumentSnapshot<Map<String, dynamic>>>;
    final before = tenantSnap.data();
    return TenantDeletePlan(
      tenantId: tenantId,
      tenantName: _displayName(before, tenantId),
      before: before == null ? null : Map<String, dynamic>.from(before),
      blockers: permanentDeleteBlockers(
        liveLedgerEntries: live(
            docs(1), (d) => isLiveLedgerEntry(LedgerEntry.fromFirestore(d))),
        liveInvoices:
            live(docs(2), (d) => isLiveInvoice(InvoiceModel.fromFirestore(d))),
        livePayments:
            live(docs(3), (d) => isLivePayment(PaymentModel.fromFirestore(d))),
        activeContracts: live(docs(4), (d) => isActiveFlagSet(d.data())),
        activeLiens:
            live(docs(5), (d) => isLiveLien(LienModel.fromFirestore(d))),
        activeSavedCards: live(docs(6), (d) => isActiveFlagSet(d.data())),
      ),
      unitIds: units.map((d) => d.id).toList(),
      heldUnitNumbers:
          unitNumbersHeldByTenant(tenantId, units.map(UnitModel.fromFirestore)),
      activeGateAccessIds: results[8] as List<String>,
    );
  }

  /// Unit unlinks, gate-code shutoff and the tenant delete, in batches, so a
  /// rules refusal of the delete frees no unit. Before, each unit was freed
  /// (and listed as rentable) before the delete was even tried.
  static Future<void> _commitDeletePlans(
    String facilityId,
    List<TenantDeletePlan> plans,
    String uid,
  ) async {
    final facilityRef = _firestore.collection('facilities').doc(facilityId);
    final unitOff =
        UnitService.tenantUnlinkFields(updatedBy: uid, moveOutDate: DateTime.now());
    final gateOff = _gateAccessOffFields(uid);
    final groups = [
      for (final plan in plans)
        <void Function(WriteBatch)>[
          for (final unitId in plan.unitIds)
            (b) => b.update(facilityRef.collection('units').doc(unitId), unitOff),
          for (final accessId in plan.activeGateAccessIds)
            (b) => b.update(
                facilityRef.collection('gateAccess').doc(accessId), gateOff),
          (b) => b.delete(facilityRef.collection('tenants').doc(plan.tenantId)),
        ],
    ];
    for (final chunk in packWriteGroups(groups)) {
      final batch = _firestore.batch();
      for (final write in chunk) {
        write(batch);
      }
      await batch.commit();
    }
  }

  static Future<List<TenantDeletePlan>> _permanentlyDelete(
    String facilityId,
    List<String> tenantIds,
    String uid,
  ) async {
    final plans = await runPermanentDelete(
      tenantIds: tenantIds,
      loadPlan: (id) => _loadDeletePlan(facilityId, id),
      commit: (plans) => _commitDeletePlans(facilityId, plans, uid),
    );
    if (plans.any((p) => p.unitIds.isNotEmpty)) {
      UnitService.schedulePublicMapInventorySync(facilityId);
    }
    return plans;
  }

  // Delete tenant permanently. Refused (TenantHasFinancialRecordsException)
  // when the tenant has billing or legal history. Otherwise unlinks their
  // units, turns off their gate codes and deletes the doc in one batch, then
  // refreshes facility counts.
  static Future<void> deleteTenant({
    required String facilityId,
    required String tenantId,
  }) async {
    try {
      final user = _auth.currentUser;
      if (user == null) {
        throw Exception('Not signed in');
      }

      await _assertFacilityAllowsPermanentTenantDeletion(facilityId);

      if (kDebugMode) {
        print('🔄 [TenantService] Deleting tenant: $tenantId (facility: $facilityId)');
      }

      final plan = (await _permanentlyDelete(facilityId, [tenantId], user.uid)).single;

      await AuditService.logEvent(
        facilityId: facilityId,
        eventType: 'tenant.deleted',
        targetType: 'tenant',
        targetId: tenantId,
        tenantId: tenantId,
        before: plan.before,
        metadata: {
          'unitsUnlinked': plan.unitIds.length,
          'gateAccessDeactivated': plan.activeGateAccessIds.length,
        },
      );

      if (kDebugMode) {
        print('✅ [TenantService] Tenant deleted: $tenantId, unlinked ${plan.unitIds.length} unit(s)');
      }

      // Refresh facility counts so dashboard/list stay correct.
      // force: a delete must be reflected immediately, not swallowed by the cooldown.
      await FacilityStatsService.updateFacilityStats(facilityId, force: true);
    } catch (e) {
      if (kDebugMode) {
        print('❌ [TenantService] Error deleting tenant: $e');
      }
      rethrow;
    }
  }

  // Delete multiple tenants permanently, all or nothing: if any selected
  // tenant has history, none are deleted. Then refresh facility counts once.
  static Future<void> deleteTenants({
    required String facilityId,
    required List<String> tenantIds,
  }) async {
    try {
      final user = _auth.currentUser;
      if (user == null) {
        throw Exception('Not signed in');
      }

      final ids = tenantIds.toSet().toList();
      if (ids.isEmpty) return;

      if (kDebugMode) {
        print('🔄 [TenantService] Deleting ${ids.length} tenants (facility: $facilityId)');
      }

      await _assertFacilityAllowsPermanentTenantDeletion(facilityId);

      final plans = await _permanentlyDelete(facilityId, ids, user.uid);
      final unlinked = plans.fold<int>(0, (n, p) => n + p.unitIds.length);

      await AuditService.logEvent(
        facilityId: facilityId,
        eventType: 'tenant.bulkDeleted',
        targetType: 'tenant',
        targetId: 'bulk_${ids.length}_${DateTime.now().millisecondsSinceEpoch}',
        metadata: {
          'tenantIds': ids,
          'count': ids.length,
          'unitsUnlinked': unlinked,
          'gateAccessDeactivated':
              plans.fold<int>(0, (n, p) => n + p.activeGateAccessIds.length),
          // Same order as tenantIds (a missing doc falls back to its id).
          'tenantNames': plans.map((p) => p.tenantName).toList(),
        },
      );

      if (kDebugMode) {
        print('✅ [TenantService] Deleted ${ids.length} tenants, unlinked $unlinked unit(s)');
      }

      // force: a bulk delete must be reflected immediately, not swallowed by
      // the cooldown. One call for the whole batch, not one per tenant.
      await FacilityStatsService.updateFacilityStats(facilityId, force: true);
    } catch (e) {
      if (kDebugMode) {
        print('❌ [TenantService] Error deleting tenants: $e');
      }
      rethrow;
    }
  }

  // Search tenants
  static Future<List<TenantModel>> searchTenants(String query) async {
    try {
      final user = _auth.currentUser;
      if (user == null) {
        throw Exception('Not signed in');
      }

      if (query.trim().isEmpty) {
        return await getAllTenants();
      }

      final allTenants = await getAllTenants();
      final normalizedQuery = query.toLowerCase().trim();

      return allTenants.where((tenant) {
        return tenant.name.toLowerCase().contains(normalizedQuery) ||
               tenant.email.toLowerCase().contains(normalizedQuery) ||
               tenant.phone.contains(normalizedQuery) ||
               tenant.unitNumber.toLowerCase().contains(normalizedQuery);
      }).toList();
    } catch (e) {
      if (kDebugMode) {
        print('❌ Error searching tenants: $e');
      }
      return [];
    }
  }

  // Helper method to update unit occupancy
  static Future<void> _updateUnitOccupancy(
    String facilityId,
    String unitNumber,
    String tenantId,
    String tenantName,
    bool occupied,
    double monthlyRate,
  ) async {
    try {
      // Find the unit by unitNumber (query all units with this number, filter active in memory)
      QuerySnapshot allUnitsSnapshot = await _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('units')
          .where('unitNumber', isEqualTo: unitNumber)
          .get();
      
      // Filter to only active units
      final activeUnits = allUnitsSnapshot.docs
          .where((doc) {
            final data = doc.data();
            final dataMap = data as Map<String, dynamic>? ?? {};
            return (dataMap['isActive'] ?? true) == true;
          })
          .toList();

      DocumentReference unitDocRef;
      
      if (activeUnits.isEmpty) {
        // Unit doesn't exist - create it automatically
        if (kDebugMode) {
          print('🔄 Unit $unitNumber not found, creating it automatically...');
        }
        
        final unitId = await UnitService.createUnit(
          facilityId: facilityId,
          unitNumber: unitNumber,
          unitType: 'standard', // Default type
          monthlyRate: monthlyRate,
        );
        
        if (kDebugMode) {
          print('✅ Unit $unitNumber created automatically with ID: $unitId');
        }
        
        // Get the newly created unit document
        unitDocRef = _firestore
            .collection('facilities')
            .doc(facilityId)
            .collection('units')
            .doc(unitId);
      } else {
        unitDocRef = activeUnits.first.reference;
      }

      final updateData = <String, dynamic>{
        'updatedAt': FieldValue.serverTimestamp(),
        'status': occupied ? 'occupied' : 'available',
      };

      if (occupied) {
        updateData['tenantId'] = tenantId;
        updateData['tenantName'] = tenantName;
        updateData['moveInDate'] = FieldValue.serverTimestamp();
      } else {
        updateData['tenantId'] = null;
        updateData['tenantName'] = null;
        updateData['moveOutDate'] = FieldValue.serverTimestamp();
      }

      await unitDocRef.update(updateData);

      if (kDebugMode) {
        print('✅ Unit $unitNumber occupancy updated: $occupied');
      }
    } catch (e) {
      if (kDebugMode) {
        print('❌ Error updating unit occupancy: $e');
      }
      rethrow;
    }
  }

}
