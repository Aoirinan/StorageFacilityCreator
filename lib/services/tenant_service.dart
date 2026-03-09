import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import '../models/tenant_model.dart';
import 'unit_service.dart';
import 'facility_limits_service.dart';
import 'audit_service.dart';
import 'facility_stats_service.dart';

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

      await _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('tenants')
          .doc(tenantId)
          .update(updateData);

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

      // Get before snapshot for audit log
      final beforeDoc = await _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('tenants')
          .doc(tenantId)
          .get();
      final beforeData = beforeDoc.exists ? beforeDoc.data() : null;

      await _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('tenants')
          .doc(tenantId)
          .update({
        'isActive': false,
        'updatedAt': FieldValue.serverTimestamp(),
      });

      // Log audit event
      await AuditService.logEvent(
        facilityId: facilityId,
        eventType: 'tenant.archived',
        targetType: 'tenant',
        targetId: tenantId,
        tenantId: tenantId,
        before: beforeData != null ? Map<String, dynamic>.from(beforeData) : null,
        after: {'isActive': false},
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

  // Delete tenant permanently.
  // Cascade: unlink all units referencing this tenant, then delete tenant doc, then refresh facility counts.
  static Future<void> deleteTenant({
    required String facilityId,
    required String tenantId,
  }) async {
    try {
      final user = _auth.currentUser;
      if (user == null) {
        throw Exception('Not signed in');
      }

      if (kDebugMode) {
        print('🔄 [TenantService] Deleting tenant: $tenantId (facility: $facilityId)');
      }

      // 1) Find and unlink all units that reference this tenant (avoid ghost data)
      final units = await UnitService.getUnitsForFacility(facilityId);
      final unitsWithTenant = units.where((u) => u.tenantId == tenantId).toList();
      if (kDebugMode) {
        print('   [TenantService] Units referencing tenant: ${unitsWithTenant.length}');
      }
      for (final unit in unitsWithTenant) {
        await UnitService.removeTenantFromUnit(
          facilityId: facilityId,
          unitId: unit.id,
          moveOutDate: DateTime.now(),
        );
        if (kDebugMode) {
          print('   [TenantService] Unlinked unit ${unit.unitNumber} (${unit.id})');
        }
      }

      // 2) Delete tenant document
      await _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('tenants')
          .doc(tenantId)
          .delete();

      if (kDebugMode) {
        print('✅ [TenantService] Tenant deleted: $tenantId, unlinked ${unitsWithTenant.length} unit(s)');
      }

      // 3) Refresh facility counts so dashboard/list stay correct
      await FacilityStatsService.updateFacilityStats(facilityId);
    } catch (e) {
      if (kDebugMode) {
        print('❌ [TenantService] Error deleting tenant: $e');
      }
      rethrow;
    }
  }

  // Delete multiple tenants permanently.
  // Cascade: for each tenant, unlink units then delete; then refresh facility counts once.
  static Future<void> deleteTenants({
    required String facilityId,
    required List<String> tenantIds,
  }) async {
    try {
      final user = _auth.currentUser;
      if (user == null) {
        throw Exception('Not signed in');
      }

      if (kDebugMode) {
        print('🔄 [TenantService] Deleting ${tenantIds.length} tenants (facility: $facilityId)');
      }

      final units = await UnitService.getUnitsForFacility(facilityId);
      final tenantIdSet = tenantIds.toSet();
      int unlinked = 0;
      for (final unit in units) {
        if (unit.tenantId != null && tenantIdSet.contains(unit.tenantId)) {
          await UnitService.removeTenantFromUnit(
            facilityId: facilityId,
            unitId: unit.id,
            moveOutDate: DateTime.now(),
          );
          unlinked++;
        }
      }

      final batch = _firestore.batch();
      final tenantsRef = _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('tenants');

      for (final tenantId in tenantIds) {
        batch.delete(tenantsRef.doc(tenantId));
      }

      await batch.commit();

      if (kDebugMode) {
        print('✅ [TenantService] Deleted ${tenantIds.length} tenants, unlinked $unlinked unit(s)');
      }

      await FacilityStatsService.updateFacilityStats(facilityId);
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
