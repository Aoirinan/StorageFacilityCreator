import 'dart:async';
import 'dart:math' as math;

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:sfcapp/models/invoice_model.dart';
import 'package:sfcapp/models/ledger_entry_model.dart';
import 'package:sfcapp/models/payment_model.dart';
import 'package:sfcapp/models/tenant_model.dart';
import 'package:sfcapp/models/unit_model.dart';
import 'package:sfcapp/services/audit_service.dart';
import 'package:sfcapp/services/facility_creator_account_service.dart';
import 'package:sfcapp/services/facility_limits_service.dart';
import 'package:sfcapp/services/facility_stats_service.dart';
import 'package:sfcapp/services/facility_service.dart';
import 'package:sfcapp/services/superadmin_service.dart';
import 'package:sfcapp/services/unit_service.dart';

/// A unit that still shows a tenant as its occupant, and how to free it.
class HeldUnit {
  const HeldUnit(this.unitNumber, this.status);

  final String unitNumber;
  final UnitStatus status;

  /// Where to go to free the unit. Unit detail only offers Unassign Tenant on
  /// an occupied unit, so "Unassign Tenant" alone led nowhere for a unit in
  /// lockout, reserved, in maintenance or at auction.
  String get freeingSteps {
    final unit = 'Units > unit $unitNumber';
    return switch (status) {
      UnitStatus.occupied || UnitStatus.available => '$unit > Unassign Tenant',
      UnitStatus.lockout ||
      UnitStatus.overlocked =>
        '$unit > Remove Lockout, then Unassign Tenant',
      UnitStatus.reserved ||
      UnitStatus.maintenance ||
      UnitStatus.outOfOrder ||
      UnitStatus.auction =>
        '$unit > Edit Unit, set Status to Occupied, then Unassign Tenant',
    };
  }

  /// "unit 101" or "units 101 and 102".
  static String label(List<HeldUnit> units) => units.length == 1
      ? 'unit ${units.single.unitNumber}'
      : 'units ${TenantService.joinReadable([
              for (final u in units) u.unitNumber
            ])}';

  /// "Unassign the unit first (Units > unit 101 > Unassign Tenant)."
  static String unassignFirst(List<HeldUnit> units) =>
      'Unassign the ${units.length == 1 ? 'unit' : 'units'} first '
      '(${units.map((u) => u.freeingSteps).join('; ')}).';

  @override
  bool operator ==(Object other) =>
      other is HeldUnit &&
      other.unitNumber == unitNumber &&
      other.status == status;

  @override
  int get hashCode => Object.hash(unitNumber, status);

  @override
  String toString() => 'HeldUnit($unitNumber, ${status.name})';
}

/// One tenant a permanent delete was refused for, and why.
class TenantDeleteBlock {
  const TenantDeleteBlock({
    required this.tenantId,
    required this.tenantName,
    this.reasons = const [],
    this.heldUnits = const [],
  });

  final String tenantId;
  final String tenantName;

  /// Billing or legal history, from [TenantService.permanentDeleteBlockers].
  final List<String> reasons;

  /// Units that still show this tenant as the occupant.
  final List<HeldUnit> heldUnits;

  /// Archive is only a safe way out for someone who holds no unit: archiving
  /// an occupant silently stops their rent, autopay and lockout.
  bool get canArchiveInstead => heldUnits.isEmpty;

  /// "has an invoice and is still assigned to unit 101".
  String get summary => [
        if (reasons.isNotEmpty) 'has ${TenantService.joinReadable(reasons)}',
        if (heldUnits.isNotEmpty)
          'is still assigned to ${HeldUnit.label(heldUnits)}',
      ].join(' and ');
}

/// Permanent delete refused for every selected tenant, because at least one
/// has billing or legal history or still holds a unit. Deleting such a tenant
/// orphaned their ledger (the balance fell out of AR and the history could no
/// longer be opened), or freed a unit that was still theirs and listed it as
/// rentable.
class TenantDeleteRefusedException implements Exception {
  const TenantDeleteRefusedException(this.blocked);

  final List<TenantDeleteBlock> blocked;

  Map<String, List<String>> get blockersByTenantName => {
        for (final b in blocked) b.tenantName: b.reasons,
      };

  String get message {
    if (blocked.length == 1) {
      final b = blocked.single;
      return 'Nothing was deleted. ${b.tenantName} ${b.summary}.';
    }
    final names =
        blocked.map((b) => '${b.tenantName} (${b.summary})').join('; ');
    return 'Nothing was deleted. ${blocked.length} of the selected tenants '
        'have to be kept for now: $names.';
  }

  /// Dialog body: what each tenant has and what to do instead. Archive is
  /// only suggested for tenants who hold no unit.
  String get details {
    if (blocked.length == 1) {
      final b = blocked.single;
      final why = b.reasons.isEmpty
          ? 'Permanent delete is only for tenants entered by mistake; deleting '
              'them would free the unit and list it as rentable.'
          : 'Permanently deleting them would orphan that history, so it has '
              'to be kept.';
      final next = b.canArchiveInstead
          ? 'You can archive ${b.tenantName} instead: they leave your active '
              'lists and their history is kept.'
          : '${HeldUnit.unassignFirst(b.heldUnits)} Then '
              '${b.reasons.isEmpty ? 'you can delete them' : 'archive them'}.';
      return '${b.tenantName} ${b.summary}. $why\n\n$next';
    }

    final lines = [
      'Nothing was deleted. These tenants have history that has to be kept, '
          'or still hold a unit:',
      for (final b in blocked)
        '• ${b.tenantName}: ${b.summary}.'
            '${b.canArchiveInstead ? '' : ' ${HeldUnit.unassignFirst(b.heldUnits)}'}',
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

enum _CheckFailure { permission, connection, other }

/// The pre-delete check could not read a tenant's records. An unreadable
/// history is not an empty one, so this refuses the delete.
class TenantDeleteCheckFailedException implements Exception {
  const TenantDeleteCheckFailedException(this.cause, {this.tenantCount = 1});

  final Object cause;

  /// How many tenants the refused delete was for.
  final int tenantCount;

  /// Worded by cause: every failure used to read "Check your connection",
  /// even a bad cast, which sent owners chasing their network.
  String get message {
    final whose = tenantCount == 1
        ? "this tenant's"
        : "the $tenantCount selected tenants'";
    final next = switch (_kind) {
      _CheckFailure.permission =>
        "Your role can't read all of them; ask the facility owner to do this.",
      _CheckFailure.connection => 'Check your connection and try again.',
      _CheckFailure.other =>
        'Try again, and contact support if it keeps happening.',
    };
    final text = "Couldn't check $whose records, so nothing was deleted. $next";
    return kDebugMode ? '$text ($cause)' : text;
  }

  _CheckFailure get _kind {
    final error = cause;
    final code = error is FirebaseException ? error.code : '';
    final text = '$code $error';
    if (text.contains('permission-denied')) return _CheckFailure.permission;
    if (error is TimeoutException ||
        const ['unavailable', 'deadline-exceeded', 'network']
            .any(text.contains)) {
      return _CheckFailure.connection;
    }
    return _CheckFailure.other;
  }

  @override
  String toString() => message;
}

/// Archive, or switching a tenant to inactive, refused while a unit still
/// shows them as the occupant.
class TenantStillAssignedToUnitException implements Exception {
  const TenantStillAssignedToUnitException({
    required this.tenantName,
    required this.units,
  });

  final String tenantName;
  final List<HeldUnit> units;

  /// Neutral on purpose: the same refusal answers Archive and the Active
  /// switch, and "then archive" read wrong after switching Active off.
  String get message =>
      '$tenantName is still assigned to ${HeldUnit.label(units)}. '
      '${HeldUnit.unassignFirst(units)} A tenant who still holds a unit '
      "can't be archived or set inactive: their rent, autopay and lockout "
      'would stop while the unit still shows them as its occupant.';

  @override
  String toString() => message;
}

/// The app's pre-check of one tenant for permanent delete. The
/// deleteTenantsPermanently callable repeats it with admin reads and is the
/// one that counts.
class TenantDeletePlan {
  const TenantDeletePlan({
    required this.tenantId,
    required this.tenantName,
    this.blockers = const [],
    this.heldUnits = const [],
  });

  final String tenantId;
  final String tenantName;

  /// Billing or legal history that rules the delete out.
  final List<String> blockers;

  /// The linked units the tenant actually occupies; any one rules the
  /// delete out too.
  final List<HeldUnit> heldUnits;

  bool get isBlocked => blockers.isNotEmpty || heldUnits.isNotEmpty;

  TenantDeleteBlock toBlock() => TenantDeleteBlock(
        tenantId: tenantId,
        tenantName: tenantName,
        reasons: blockers,
        heldUnits: heldUnits,
      );
}

/// Writes the tenant guards make, all under one facility. [collection] is a
/// facility subcollection: tenants, units or gateAccess.
abstract class TenantRecordsWriter {
  void update(String collection, String docId, Map<String, dynamic> fields);
}

/// A [TenantRecordsWriter] inside a transaction, which can also re-read a
/// unit. Reads come before writes, as Firestore requires.
abstract class TenantRecordsTransaction implements TenantRecordsWriter {
  /// The unit's tenantId as of this transaction; null when it has none or
  /// the unit is gone.
  Future<String?> unitTenantId(String unitId);
}

/// The reads and writes behind the permanent delete pre-check, archive and
/// switching a tenant inactive, for one facility. A seam: the guards, and
/// what they write, are tested against a fake without Firebase.
abstract class TenantRecordsStore {
  /// The tenant doc's data, or null if it doesn't exist.
  Future<Map<String, dynamic>?> tenant(String tenantId);

  /// Up to [limit] rows of a facility [collection] whose tenantId is
  /// [tenantId].
  Future<List<Map<String, dynamic>>> facilityRows(
      String collection, String tenantId, int limit);

  /// Up to [limit] rows of the tenant's own [subcollection].
  Future<List<Map<String, dynamic>>> tenantRows(
      String tenantId, String subcollection, int limit);

  /// One doc of the tenant's [subcollection], or null.
  Future<Map<String, dynamic>?> tenantSubdoc(
      String tenantId, String subcollection, String docId);

  /// Non-archived units whose tenantId is [tenantId]. Throws on a read
  /// error, so callers fail closed rather than reading "no units".
  Future<List<UnitModel>> linkedUnits(String tenantId);

  /// Ids of the tenant's gate codes that are still on.
  Future<List<String>> activeGateAccessIds(String tenantId);

  /// Runs [body] as one transaction. It may run more than once.
  Future<void> transaction(
      Future<void> Function(TenantRecordsTransaction txn) body);
}

/// [TenantRecordsStore] over one facility in Firestore.
class _FirestoreTenantRecords implements TenantRecordsStore {
  _FirestoreTenantRecords(this._facility);

  final DocumentReference<Map<String, dynamic>> _facility;

  DocumentReference<Map<String, dynamic>> _tenantRef(String tenantId) =>
      _facility.collection('tenants').doc(tenantId);

  @override
  Future<Map<String, dynamic>?> tenant(String tenantId) async =>
      (await _tenantRef(tenantId).get()).data();

  @override
  Future<List<Map<String, dynamic>>> facilityRows(
      String collection, String tenantId, int limit) async {
    final snap = await _facility
        .collection(collection)
        .where('tenantId', isEqualTo: tenantId)
        .limit(limit)
        .get();
    return [for (final d in snap.docs) d.data()];
  }

  @override
  Future<List<Map<String, dynamic>>> tenantRows(
      String tenantId, String subcollection, int limit) async {
    final snap =
        await _tenantRef(tenantId).collection(subcollection).limit(limit).get();
    return [for (final d in snap.docs) d.data()];
  }

  @override
  Future<Map<String, dynamic>?> tenantSubdoc(
          String tenantId, String subcollection, String docId) async =>
      (await _tenantRef(tenantId).collection(subcollection).doc(docId).get())
          .data();

  @override
  Future<List<UnitModel>> linkedUnits(String tenantId) async {
    final snap = await _facility
        .collection('units')
        .where('tenantId', isEqualTo: tenantId)
        .get();
    return [
      for (final d in snap.docs)
        if (d.data()['archived'] != true) UnitModel.fromFirestore(d),
    ];
  }

  @override
  Future<List<String>> activeGateAccessIds(String tenantId) async {
    final snap = await _facility
        .collection('gateAccess')
        .where('tenantId', isEqualTo: tenantId)
        .get();
    return [
      for (final d in snap.docs)
        if (TenantService.isActiveFlagSet(d.data())) d.id,
    ];
  }

  @override
  Future<void> transaction(
      Future<void> Function(TenantRecordsTransaction txn) body) {
    return _facility.firestore.runTransaction<void>(
        (txn) => body(_FirestoreTenantTransaction(_facility, txn)));
  }
}

class _FirestoreTenantTransaction implements TenantRecordsTransaction {
  _FirestoreTenantTransaction(this._facility, this._txn);

  final DocumentReference<Map<String, dynamic>> _facility;
  final Transaction _txn;

  DocumentReference<Map<String, dynamic>> _ref(String collection, String id) =>
      _facility.collection(collection).doc(id);

  @override
  Future<String?> unitTenantId(String unitId) async {
    final snap = await _txn.get(_ref('units', unitId));
    final tenantId = snap.data()?['tenantId'];
    return tenantId is String ? tenantId : null;
  }

  @override
  void update(String collection, String docId, Map<String, dynamic> fields) {
    _txn.update(_ref(collection, docId), fields);
  }
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
      ({int unitsFreed, int gateCodesOff})? deactivation;
      if (deactivating) {
        // Every deactivation is checked, not only the Active switch: the edit
        // screen always passes a unit number ('' for a tenant assigned from
        // the Units screen), so the old unitNumber == null check never ran
        // there and turned off a paying occupant's gate code.
        deactivation = await deactivateForUpdate(
          _records(facilityId),
          tenantId: tenantId,
          before: beforeData,
          requestedUnitNumber: unitNumber,
          updateData: updateData,
          uid: user.uid,
        );
      } else {
        await _firestore
            .collection('facilities')
            .doc(facilityId)
            .collection('tenants')
            .doc(tenantId)
            .update(updateData);
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
          if (deactivation != null) ...{
            'unitsFreed': deactivation.unitsFreed,
            'gateAccessDeactivated': deactivation.gateCodesOff,
          },
        },
      );

      if (deactivation != null && deactivation.unitsFreed > 0) {
        await FacilityStatsService.updateFacilityStats(facilityId);
        UnitService.schedulePublicMapInventorySync(facilityId);
      }

      // Keep facilities/{id}/units in sync when unit number changes (createTenant already does this).
      // A deactivation already freed its units, in the same transaction.
      if (unitNumber != null && beforeData != null && !deactivating) {
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

      // Refused while the tenant still holds a unit; turns their gate codes
      // off in the same transaction as the archive.
      final archived = await archiveWith(_records(facilityId), tenantId, uid: user.uid);
      final beforeData = archived.before;

      // Log audit event
      await AuditService.logEvent(
        facilityId: facilityId,
        eventType: 'tenant.archived',
        targetType: 'tenant',
        targetId: tenantId,
        tenantId: tenantId,
        before: beforeData != null ? Map<String, dynamic>.from(beforeData) : null,
        after: {'isActive': false},
        metadata: {'gateAccessDeactivated': archived.gateCodesOff},
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
  /// A fast pre-check: the deleteTenantsPermanently callable enforces the
  /// same gate (facilityAllowsPermanentTenantDelete in functions-shared).
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
  // billing or legal history, or who still holds a unit, is refused, because
  // deleting the tenant doc orphaned their ledger, invoices and payments: the
  // balance vanished from AR and the history could no longer be opened.
  // Archive keeps it.
  //
  // The deleteTenantsPermanently callable (functions-tenant-lifecycle)
  // enforces this and does the delete; the rules no longer let owners or
  // managers delete a tenant doc, so an old tab or a direct API call can't
  // skip the check. The copy here is a fast pre-check that refuses without a
  // round trip.
  //
  // PARITY: isLiveLedgerRow, isLiveInvoiceRow, isLivePaymentRow,
  // isLiveCardPaymentRow, hasAutopaySubscription, isActiveFlagSet,
  // scanLiveRows, permanentDeleteBlockers, unitsHeldByTenant and
  // loadDeletePlan mirror functions-shared/src/tenants/permanentDeleteRules.ts,
  // and the callable's refusals are shown with these same strings. Both test
  // suites run functions-shared/src/test/fixtures/tenantDeleteParity.json;
  // change a rule on one side, change the other and add a case there.

  /// Rows read per collection when checking a tenant for history
  /// (TENANT_DELETE_SCAN_LIMIT on the server).
  static const int _deleteCheckScanLimit = 10;

  /// Tenants checked at once in a bulk delete; each check is ~10 reads.
  static const int _deleteCheckConcurrency = 8;

  static TenantRecordsStore _records(String facilityId) =>
      _FirestoreTenantRecords(_firestore.collection('facilities').doc(facilityId));

  static String _statusOf(Map<String, dynamic> row) =>
      (row['status'] as Object?)?.toString().trim().toLowerCase() ?? '';

  /// Posted or pending. A voided entry was reversed and leaves nothing behind.
  static bool isLiveLedgerRow(Map<String, dynamic> row) =>
      _statusOf(row) != LedgerEntryStatus.voided.name;

  /// Draft, sent, paid and overdue invoices are all history; only voided is not.
  static bool isLiveInvoiceRow(Map<String, dynamic> row) =>
      _statusOf(row) != InvoiceStatus.voided.name;

  /// Payment statuses that never moved money ('canceled' is Stripe's
  /// spelling, used on the tenant's own payment rows).
  static final _deadPaymentStatuses = {
    PaymentStatus.failed.name,
    PaymentStatus.cancelled.name,
    'canceled',
  };

  /// Failed and cancelled payments never moved money, and archived ones were
  /// removed on purpose. Everything else (pending, paid, refunded, disputed,
  /// and statuses not known here) is real history.
  static bool isLivePaymentRow(Map<String, dynamic> row) =>
      row['isActive'] != false &&
      !_deadPaymentStatuses.contains(_statusOf(row));

  /// A row of tenants/{id}/payments. The card-payment callables write it as
  /// 'processing' before Stripe charges, and only the webhook writes the
  /// facility payment and ledger rows. Deleting in between left the webhook
  /// writing money for a tenant who no longer existed.
  static bool isLiveCardPaymentRow(Map<String, dynamic> row) =>
      !_deadPaymentStatuses.contains(_statusOf(row));

  /// billing/default holds the tenant's Stripe autopay subscription while it
  /// is armed. Deleting the tenant left Stripe charging them with nowhere to
  /// record the payments.
  static bool hasAutopaySubscription(Map<String, dynamic>? billing) {
    final id = billing?['stripeSubscriptionId'];
    return id is String && id.trim().isNotEmpty;
  }

  /// Saved cards and gate codes count as on unless switched off. A missing
  /// flag means on, as in their models.
  static bool isActiveFlagSet(Map<String, dynamic>? data) =>
      data?['isActive'] != false;

  /// How many rows of a capped scan are live. A row that can't be read
  /// counts as live. A full page with none live is [inconclusive]: rows past
  /// the cap may be live, so deleting on a guess could orphan them.
  static ({int live, bool inconclusive}) scanLiveRows<T>(
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
    return (live: live, inconclusive: live == 0 && total >= scanLimit);
  }

  /// Readable history that rules out a permanent delete; empty means none.
  /// Gated on history, not balance: a tenant charged $150 who paid $150 owes
  /// nothing but is still a real customer.
  static List<String> permanentDeleteBlockers({
    int liveLedgerEntries = 0,
    int liveInvoices = 0,
    int livePayments = 0,
    int liveCardPayments = 0,
    int contracts = 0,
    int liens = 0,
    int activeSavedCards = 0,
    bool hasAutopaySubscription = false,
    bool moreThanChecked = false,
  }) {
    String counted(int n, String one, String many) => n == 1 ? one : many;
    final reasons = [
      if (liveLedgerEntries > 0) 'charges or payments on the ledger',
      if (liveInvoices > 0) counted(liveInvoices, 'an invoice', 'invoices'),
      if (livePayments > 0)
        counted(livePayments, 'a payment record', 'payment records'),
      if (liveCardPayments > 0) 'a card payment in progress or payment history',
      if (contracts > 0) counted(contracts, 'a contract', 'contracts'),
      if (liens > 0) counted(liens, 'a lien', 'liens'),
      if (activeSavedCards > 0)
        counted(activeSavedCards, 'a saved card', 'saved cards'),
      if (hasAutopaySubscription) 'an autopay subscription',
    ];
    // Its own reason: counting a full page of voided rows as "charges on the
    // ledger" sent owners looking for charges that weren't there. Only when
    // nothing else blocks, since beside a real reason it adds nothing.
    if (reasons.isEmpty && moreThanChecked) {
      reasons.add('more records than could be checked here');
    }
    return reasons;
  }

  /// Units that still show [tenantId] as their occupant, less those whose
  /// number is in [releasing] (units the same write frees). A unit marked
  /// available with a stale link is not held: it has no Unassign button, so
  /// counting it would leave the owner stuck.
  static List<HeldUnit> unitsHeldByTenant(
    String tenantId,
    Iterable<UnitModel> units, {
    Set<String> releasing = const {},
  }) {
    return [
      for (final u in units)
        if (u.tenantId == tenantId &&
            u.status != UnitStatus.available &&
            !releasing.contains(u.unitNumber.trim()))
          HeldUnit(u.unitNumber, u.status),
    ];
  }

  /// Unit numbers an [updateTenant] call that switches the tenant off
  /// frees: the old and the new number when it sets one (an inactive
  /// tenant is never given a unit), nothing when it doesn't (the Active
  /// switch leaves units alone).
  static Set<String> unitNumbersReleasedByUpdate({
    String? previous,
    String? requested,
  }) {
    if (requested == null) return const {};
    return {previous?.trim() ?? '', requested.trim()}..remove('');
  }

  /// Whether a unit doc shows [tenantId] as its occupant. Freeing by number
  /// alone let a stale tenant.unitNumber free another tenant's unit.
  static bool isUnitLinkedTo(String tenantId, Map<String, dynamic>? unit) =>
      unit?['tenantId'] == tenantId;

  /// "a", "a and b", "a, b and c".
  static String joinReadable(List<String> parts) {
    if (parts.length <= 1) return parts.join();
    return '${parts.sublist(0, parts.length - 1).join(', ')} and ${parts.last}';
  }

  /// Runs [run] for every item, [concurrency] at a time, results in order.
  static Future<List<R>> _inGroups<T, R>(
    List<T> items,
    Future<R> Function(T item) run, {
    int concurrency = _deleteCheckConcurrency,
  }) async {
    final results = <R>[];
    for (var i = 0; i < items.length; i += concurrency) {
      final slice = items.sublist(i, math.min(i + concurrency, items.length));
      results.addAll(await Future.wait(slice.map(run)));
    }
    return results;
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
    try {
      return await _inGroups(tenantIds, load, concurrency: concurrency);
    } on TenantDeleteCheckFailedException {
      rethrow;
    } catch (e) {
      throw TenantDeleteCheckFailedException(e, tenantCount: tenantIds.length);
    }
  }

  /// The order that makes permanent delete safe: read every tenant first,
  /// refuse them all if any is blocked (the dialog said "Delete N"), and
  /// only then write. [commit] is never called on a refusal.
  @visibleForTesting
  static Future<List<TenantDeletePlan>> runPermanentDelete({
    required List<String> tenantIds,
    required Future<TenantDeletePlan> Function(String tenantId) loadPlan,
    required Future<void> Function(List<TenantDeletePlan> plans) commit,
  }) async {
    final plans = await loadAllForDelete(tenantIds, loadPlan);
    final blocked =
        plans.where((p) => p.isBlocked).map((p) => p.toBlock()).toList();
    if (blocked.isNotEmpty) {
      throw TenantDeleteRefusedException(blocked);
    }
    await commit(plans);
    return plans;
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

  /// Switches a tenant off: refuses while a unit not in [releasing] still
  /// shows them as its occupant, then writes [tenantUpdate], frees the
  /// [releasing] units still linked to them and turns their gate codes off,
  /// all in one transaction. Before, the gate codes were turned off best
  /// effort after the update, so a failure left an inactive tenant with a
  /// working code.
  @visibleForTesting
  static Future<({int unitsFreed, int gateCodesOff})> commitDeactivation(
    TenantRecordsStore store, {
    required String tenantId,
    required String tenantName,
    required Map<String, dynamic> tenantUpdate,
    required String uid,
    Set<String> releasing = const {},
  }) async {
    final units = await store.linkedUnits(tenantId);
    // Rent, autopay and delinquency jobs skip inactive tenants, so switching
    // off someone who still holds a unit silently stopped their rent and
    // lockout while the unit kept showing them as its occupant.
    final held = unitsHeldByTenant(tenantId, units, releasing: releasing);
    if (held.isNotEmpty) {
      throw TenantStillAssignedToUnitException(
          tenantName: tenantName, units: held);
    }
    final toFree = [
      for (final u in units)
        if (releasing.contains(u.unitNumber.trim())) u.id,
    ];
    final gateIds = await store.activeGateAccessIds(tenantId);
    final unitOff = UnitService.tenantUnlinkFields(updatedBy: uid);
    final gateOff = _gateAccessOffFields(uid);
    var freed = 0;
    await store.transaction((txn) async {
      freed = 0;
      final holders = await Future.wait(toFree.map(txn.unitTenantId));
      final holderOf = Map.fromIterables(toFree, holders);
      txn.update('tenants', tenantId, tenantUpdate);
      for (final unitId in toFree) {
        if (holderOf[unitId] != tenantId) continue;
        txn.update('units', unitId, unitOff);
        freed++;
      }
      for (final accessId in gateIds) {
        txn.update('gateAccess', accessId, gateOff);
      }
    });
    return (unitsFreed: freed, gateCodesOff: gateIds.length);
  }

  /// Archive: switch the tenant off, freeing nothing.
  @visibleForTesting
  static Future<({Map<String, dynamic>? before, int gateCodesOff})>
      archiveWith(
    TenantRecordsStore store,
    String tenantId, {
    required String uid,
  }) async {
    final before = await store.tenant(tenantId);
    final result = await commitDeactivation(
      store,
      tenantId: tenantId,
      tenantName: _displayName(before, tenantId),
      tenantUpdate: {
        'isActive': false,
        'updatedAt': FieldValue.serverTimestamp(),
      },
      uid: uid,
    );
    return (before: before, gateCodesOff: result.gateCodesOff);
  }

  /// The part of [updateTenant] that switches a tenant off, [before] being
  /// the tenant doc as read and [requestedUnitNumber] the call's unitNumber.
  @visibleForTesting
  static Future<({int unitsFreed, int gateCodesOff})> deactivateForUpdate(
    TenantRecordsStore store, {
    required String tenantId,
    required Map<String, dynamic> before,
    required String? requestedUnitNumber,
    required Map<String, dynamic> updateData,
    required String uid,
  }) {
    return commitDeactivation(
      store,
      tenantId: tenantId,
      tenantName: _displayName(before, tenantId),
      tenantUpdate: updateData,
      uid: uid,
      releasing: unitNumbersReleasedByUpdate(
        previous: (before['unitNumber'] as Object?)?.toString(),
        requested: requestedUnitNumber,
      ),
    );
  }

  /// Reads what the permanent delete pre-check of [tenantId] needs. Every
  /// query is equality on tenantId only, so the single-field indexes serve
  /// them and no composite index is needed.
  @visibleForTesting
  static Future<TenantDeletePlan> loadDeletePlan(
    TenantRecordsStore store,
    String tenantId,
  ) async {
    const limit = _deleteCheckScanLimit;
    // Started together and read back by name: the old list was read by
    // index, where one slip matches a result to the wrong reason.
    final tenantRead = store.tenant(tenantId);
    final ledgerRead = store.facilityRows('ledgers', tenantId, limit);
    final invoicesRead = store.facilityRows('invoices', tenantId, limit);
    final paymentsRead = store.facilityRows('payments', tenantId, limit);
    final contractsRead = store.facilityRows('contracts', tenantId, limit);
    final liensRead = store.facilityRows('liens', tenantId, limit);
    final cardsRead = store.tenantRows(tenantId, 'paymentMethods', limit);
    final cardPaymentsRead = store.tenantRows(tenantId, 'payments', limit);
    final billingRead = store.tenantSubdoc(tenantId, 'billing', 'default');
    final unitsRead = store.linkedUnits(tenantId);
    // Future.wait fails on the first error and handles the others, so a
    // second failed read can't surface as an uncaught error.
    await Future.wait<Object?>([
      tenantRead,
      ledgerRead,
      invoicesRead,
      paymentsRead,
      contractsRead,
      liensRead,
      cardsRead,
      cardPaymentsRead,
      billingRead,
      unitsRead,
    ]);

    var moreThanChecked = false;
    int live(
      List<Map<String, dynamic>> rows,
      bool Function(Map<String, dynamic> row) isLive,
    ) {
      final scan = scanLiveRows(rows, isLive, scanLimit: limit);
      moreThanChecked = moreThanChecked || scan.inconclusive;
      return scan.live;
    }

    // Any contract or lien counts, active or not: history, not state. An
    // ended contract or a released lien is still a legal record.
    bool anyRow(Map<String, dynamic> _) => true;

    final ledger = live(await ledgerRead, isLiveLedgerRow);
    final invoices = live(await invoicesRead, isLiveInvoiceRow);
    final payments = live(await paymentsRead, isLivePaymentRow);
    final contracts = live(await contractsRead, anyRow);
    final liens = live(await liensRead, anyRow);
    final cards = live(await cardsRead, isActiveFlagSet);
    final cardPayments = live(await cardPaymentsRead, isLiveCardPaymentRow);
    return TenantDeletePlan(
      tenantId: tenantId,
      tenantName: _displayName(await tenantRead, tenantId),
      blockers: permanentDeleteBlockers(
        liveLedgerEntries: ledger,
        liveInvoices: invoices,
        livePayments: payments,
        liveCardPayments: cardPayments,
        contracts: contracts,
        liens: liens,
        activeSavedCards: cards,
        hasAutopaySubscription: hasAutopaySubscription(await billingRead),
        moreThanChecked: moreThanChecked,
      ),
      // An occupant is refused too: deleting them freed their unit and
      // listed it as rentable, even with no billing history yet.
      heldUnits: unitsHeldByTenant(tenantId, await unitsRead),
    );
  }

  static int _countIn(Object? value) => value is num ? value.toInt() : 0;

  /// A held unit as the callable reports it. It never reports an available
  /// unit as held, so an unknown status falls back to the plain
  /// Unassign Tenant step.
  static HeldUnit _heldUnitFromServer(Map<Object?, Object?> unit) => HeldUnit(
        '${unit['unitNumber'] ?? ''}',
        UnitStatus.values.firstWhere(
          (s) => s.name == unit['status'],
          orElse: () => UnitStatus.occupied,
        ),
      );

  /// Reads the deleteTenantsPermanently response: the units freed and gate
  /// codes turned off, or a [TenantDeleteRefusedException] naming each
  /// blocked tenant with the same reasons and steps as the pre-check.
  @visibleForTesting
  static ({int unitsUnlinked, int gateCodesOff}) parseServerDeleteResult(
      Object? data) {
    final result = data is Map ? data : const <Object?, Object?>{};
    switch (result['status']) {
      case 'deleted':
        return (
          unitsUnlinked: _countIn(result['unitsUnlinked']),
          gateCodesOff: _countIn(result['gateAccessDeactivated']),
        );
      case 'refused':
        final blocked = [
          for (final b in result['blocked'] as List? ?? const [])
            if (b is Map)
              TenantDeleteBlock(
                tenantId: '${b['tenantId'] ?? ''}',
                tenantName: '${b['tenantName'] ?? b['tenantId'] ?? ''}',
                reasons: [
                  for (final r in b['reasons'] as List? ?? const [])
                    if (r is String) r,
                ],
                heldUnits: [
                  for (final u in b['heldUnits'] as List? ?? const [])
                    if (u is Map) _heldUnitFromServer(u),
                ],
              ),
        ];
        if (blocked.isNotEmpty) throw TenantDeleteRefusedException(blocked);
    }
    // Neither answer: don't report a delete that may not have happened.
    throw Exception("Couldn't confirm the delete. Refresh the tenant list to "
        'see what changed.');
  }

  /// Checks, then deletes, every tenant in [tenantIds], or none. The
  /// pre-check refuses without a round trip when this user can already see
  /// a blocker (or can't read the records); otherwise [deleteOnServer] sends
  /// the ids to the deleteTenantsPermanently callable, which checks again
  /// inside the transaction that deletes, and its answer is final. The
  /// callable also unlinks the units, turns the gate codes off and writes
  /// the audit rows.
  @visibleForTesting
  static Future<({int unitsUnlinked, int gateCodesOff})> permanentlyDelete(
    TenantRecordsStore store,
    List<String> tenantIds, {
    required Future<Object?> Function(List<String> tenantIds) deleteOnServer,
  }) async {
    ({int unitsUnlinked, int gateCodesOff})? result;
    await runPermanentDelete(
      tenantIds: tenantIds,
      loadPlan: (id) => loadDeletePlan(store, id),
      commit: (_) async =>
          result = parseServerDeleteResult(await deleteOnServer(tenantIds)),
    );
    return result!;
  }

  static Future<Object?> _deleteOnServer(
      String facilityId, List<String> tenantIds) async {
    final result = await FirebaseFunctions.instance
        .httpsCallable(
          'deleteTenantsPermanently',
          options: HttpsCallableOptions(timeout: const Duration(seconds: 120)),
        )
        .call<dynamic>({'facilityId': facilityId, 'tenantIds': tenantIds});
    return result.data;
  }

  /// [permanentlyDelete] for a facility, then the public map resynced if a
  /// unit was freed, as before the delete moved to the server (the unit
  /// write trigger resyncs it too).
  static Future<({int unitsUnlinked, int gateCodesOff})>
      _permanentlyDeleteInFacility(
    String facilityId,
    List<String> tenantIds,
  ) async {
    final result = await permanentlyDelete(
      _records(facilityId),
      tenantIds,
      deleteOnServer: (ids) => _deleteOnServer(facilityId, ids),
    );
    if (result.unitsUnlinked > 0) {
      UnitService.schedulePublicMapInventorySync(facilityId);
    }
    return result;
  }

  // Delete tenant permanently. Refused (TenantDeleteRefusedException) when
  // the tenant has billing or legal history or still holds a unit. The
  // deleteTenantsPermanently callable unlinks their units, turns off their
  // gate codes, deletes the doc and audit-logs it in one transaction; then
  // facility counts are refreshed.
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

      final result = await _permanentlyDeleteInFacility(facilityId, [tenantId]);

      if (kDebugMode) {
        print('✅ [TenantService] Tenant deleted: $tenantId, unlinked ${result.unitsUnlinked} unit(s)');
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
  // tenant is blocked, none are deleted. The callable logs a tenant.deleted
  // event per tenant (with its before snapshot) and one tenant.bulkDeleted
  // event. Then refresh facility counts once.
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

      final result = await _permanentlyDeleteInFacility(facilityId, ids);

      if (kDebugMode) {
        print('✅ [TenantService] Deleted ${ids.length} tenants, unlinked ${result.unitsUnlinked} unit(s)');
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

      if (!occupied) {
        // Free only a unit that still shows this tenant as its occupant.
        // Matching by number alone let a stale tenant.unitNumber free
        // another tenant's unit and list it as rentable (and created the
        // unit when it didn't exist, just to mark it available).
        final linked = activeUnits.where((doc) =>
            isUnitLinkedTo(tenantId, doc.data() as Map<String, dynamic>?));
        if (linked.isEmpty) {
          if (kDebugMode) {
            print('ℹ️ Unit $unitNumber is not linked to $tenantId; left as is');
          }
          return;
        }
        unitDocRef = linked.first.reference;
      } else if (activeUnits.isEmpty) {
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
