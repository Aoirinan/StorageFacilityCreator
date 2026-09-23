import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:sfcapp/utils/callable_failure.dart';
import '../models/facility_model.dart';
import '../models/facility_creator_account_model.dart';
import 'permission_service.dart';
import 'facility_creator_account_service.dart';
import 'superadmin_service.dart';
import 'debug_logger.dart';
import 'facility_creation_policy.dart';
import '../constants/facility_capacity.dart';

void _facilityServiceDebugLog(String message) {
  if (kDebugMode) {
    // Used to call itself, which overflowed the stack on the first debug
    // log in any debug build. Release builds never reached it.
    debugPrint(message);
  }
}

/// Helper class for facility creation permission check
class _CanCreateFacilityResult {
  final bool allowed;
  final String? reason;

  const _CanCreateFacilityResult({
    required this.allowed,
    this.reason,
  });
}

class FacilityService {
  static final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  static final FirebaseAuth _auth = FirebaseAuth.instance;
  static List<FacilityModel>? _cachedFacilities;
  static DateTime? _lastFacilitiesFetch;
  static const Duration _facilityCacheTtl = Duration(minutes: 2);

  /// Clears in-memory facility list cache (e.g. after accepting an invite).
  static void clearFacilitiesCache() {
    _cachedFacilities = null;
    _lastFacilitiesFetch = null;
  }

  /// Facilities the user can access via `user_roles` (invited staff), excluding pure duplicates of [ownedIds].
  static Future<List<FacilityModel>> _facilitiesFromActiveUserRoles(
    String uid, {
    required bool includeArchived,
    Set<String>? ownedIds,
  }) async {
    try {
      final snap = await _firestore
          .collection(PermissionService.userRolesCollection)
          .where('userId', isEqualTo: uid)
          .where('isActive', isEqualTo: true)
          .get();

      final ids = <String>{};
      for (final doc in snap.docs) {
        final fid = doc.data()['facilityId'] as String?;
        if (fid == null || fid.isEmpty) continue;
        if (ownedIds != null && ownedIds.contains(fid)) continue;
        ids.add(fid);
      }
      if (ids.isEmpty) return [];

      final out = <FacilityModel>[];
      for (final id in ids) {
        final d = await _firestore.collection('facilities').doc(id).get();
        if (!d.exists) continue;
        final f = FacilityModel.fromFirestore(d);
        if (!includeArchived && !f.active) continue;
        out.add(f);
      }
      return out;
    } catch (e) {
      if (kDebugMode) {
        _facilityServiceDebugLog('❌ [FacilityService] Error loading role-based facilities: $e');
      }
      return [];
    }
  }

  static Future<bool> _userMayReadFacilityDoc({
    required String facilityId,
    required Map<String, dynamic> data,
    required User user,
  }) async {
    if (SuperAdminService.isSuperAdmin(user)) return true;
    if (data['ownerUid'] == user.uid) return true;
    final managers = data['managers'] as Map<String, dynamic>?;
    if (managers != null && managers[user.uid] == true) return true;
    final roles = data['roles'] as Map<String, dynamic>?;
    if (roles != null && roles[user.uid] != null) return true;

    try {
      final qs = await _firestore
          .collection(PermissionService.userRolesCollection)
          .where('userId', isEqualTo: user.uid)
          .where('facilityId', isEqualTo: facilityId)
          .limit(8)
          .get();
      for (final doc in qs.docs) {
        if (doc.data()['isActive'] == true) return true;
      }
    } catch (e) {
      if (kDebugMode) {
        _facilityServiceDebugLog('⚠️ [FacilityService] user_roles lookup for getFacility: $e');
      }
    }
    return false;
  }
  
  // Track if backfill has been run to avoid multiple runs
  static bool _backfillCompleted = false;

  // One-time backfill utility for existing facilities missing required fields
  static Future<void> runBackfillIfNeeded() async {
    if (_backfillCompleted) return;
    
    try {
      final user = _auth.currentUser;
      if (user == null) {
        if (kDebugMode) {
          _facilityServiceDebugLog('⚠️ No user signed in, skipping backfill');
        }
        return;
      }

      if (kDebugMode) {
        _facilityServiceDebugLog('🔄 Running facility backfill for user: ${user.uid}');
      }

      final snapshot = await _firestore
          .collection('facilities')
          .where('ownerUid', isEqualTo: user.uid)
          .get();

      final batch = _firestore.batch();
      bool needsUpdate = false;

      for (final doc in snapshot.docs) {
        final data = doc.data();
        bool docNeedsUpdate = false;
        final updates = <String, dynamic>{};

        // Fix missing active field
        if (data['active'] == null) {
          updates['active'] = true;
          docNeedsUpdate = true;
          if (kDebugMode) {
            _facilityServiceDebugLog('🔧 Fixing facility: ${data['name']} - setting active: true');
          }
        }

        // Fix missing ownerUid (shouldn't happen but be safe)
        if (data['ownerUid'] == null || data['ownerUid'] != user.uid) {
          if (kDebugMode) {
            _facilityServiceDebugLog('❌ ERROR: Facility ${data['name']} has invalid ownerUid, blocking unsafe update');
          }
          continue; // Skip this doc to prevent security issues
        }

        final roles = (data['roles'] as Map<String, dynamic>?) ?? const {};
        if (roles[user.uid] != 'owner') {
          updates['roles.${user.uid}'] = 'owner';
          docNeedsUpdate = true;
          if (kDebugMode) {
            _facilityServiceDebugLog('🔧 Ensuring owner role entry for facility: ${data['name']}');
          }
        }

        if (docNeedsUpdate) {
          batch.update(doc.reference, updates);
          needsUpdate = true;
        }
      }

      if (needsUpdate) {
        await batch.commit();
        if (kDebugMode) {
          _facilityServiceDebugLog('✅ Facility backfill completed');
        }
      } else {
        if (kDebugMode) {
          _facilityServiceDebugLog('✅ No facilities need backfill');
        }
      }

      _backfillCompleted = true;
    } catch (e) {
      if (kDebugMode) {
        _facilityServiceDebugLog('⚠️ Error during facility backfill: $e');
      }
      // Don't rethrow - backfill is non-critical
    }
  }

      // Create a new facility with improved connectivity handling
      static Future<String> createFacility({
        required String name,
        String? logoUrl,
        String? address,
        String? phone,
        String? email,
        String? timeZone,
        Map<String, dynamic>? businessHours,
        Map<String, dynamic>? gateHours,
        Map<String, dynamic>? billingSettings,
        String? paymentProcessor, // 'stripe' | 'square'; null = decide later
        int totalUnits = 0, // Physical capacity - set at creation, used for occupancy math
        bool skipSubscriptionCheck = false, // For superadmins or testing
      }) async {
        try {
          final user = _auth.currentUser;
          if (user == null) {
            throw Exception('Not signed in');
          }

          if (kDebugMode) {
            _facilityServiceDebugLog('Creating facility: $name for user: ${user.uid}');
          }

          // ✅ Phase 7: Check subscription status before creating facility
          // Superadmins bypass this check
          if (!skipSubscriptionCheck && !SuperAdminService.isSuperAdmin(user)) {
            final account = await FacilityCreatorAccountService.getOrCreateAccountForCurrentUser();
            final currentFacilityCount = account.facilityIds.length;

            // Per-facility billing: each facility gets its own subscription
            // right after creation, so the account-level trial and status are
            // legacy leftovers and must not gate a second facility.
            List<FacilityModel> existing = const [];
            try {
              existing = await getUserFacilities(includeArchived: false, forceRefresh: false);
            } catch (e) {
              _facilityServiceDebugLog('⚠️ Could not load facilities for billing-model check: $e');
            }
            final perFacilityBilling =
                usesPerFacilityBilling(existing.map((f) => f.stripePlatformSubscriptionId));

            if (!perFacilityBilling) {
              // Legacy account-level rules.
              final canCreate = _canCreateFacility(account, currentFacilityCount);

              if (!canCreate.allowed) {
                throw Exception(canCreate.reason ?? 'Subscription required to create facilities');
              }

              // Check facility count limits
              if (currentFacilityCount >= 1 && account.hasTrial) {
                throw Exception(
                  'Trial users can only create 1 facility. Please subscribe to create additional facilities.'
                );
              }

              if (currentFacilityCount >= 1 && !account.hasActiveSubscription) {
                throw Exception(
                  'Active subscription required to create additional facilities. Please subscribe to continue.'
                );
              }
            }
          }

          // Enforce totalUnits: required, 1–kMaxFacilityCapacityUnits
          if (totalUnits < 1 || totalUnits > kMaxFacilityCapacityUnits) {
            throw Exception(
              'Total units must be between 1 and $kMaxFacilityCapacityUnits.',
            );
          }

          final ref = _firestore.collection('facilities').doc();
          final facilityData = {
            'name': name,
            'ownerUid': user.uid,  // ✅ REQUIRED by Firestore rules
            'createdAt': FieldValue.serverTimestamp(),
            'updatedAt': FieldValue.serverTimestamp(),
            'totalUnits': totalUnits, // Physical capacity - fixed at creation
            'occupiedUnits': 0,
            'active': true,  // ✅ Explicitly set as active - NEVER appears in archived
            'roles': {
              user.uid: 'owner',
            },
            if (logoUrl != null) 'logoUrl': logoUrl,
            if (address != null) 'address': address,
            if (phone != null) 'phone': phone,
            if (email != null) 'email': email,
            if (timeZone != null) 'timeZone': timeZone,
            if (businessHours != null) 'businessHours': businessHours,
            if (gateHours != null) 'gateHours': gateHours,
            if (billingSettings != null) 'billingSettings': billingSettings,
            if (paymentProcessor != null) 'paymentProcessor': paymentProcessor,
          };

          if (kDebugMode) {
            _facilityServiceDebugLog('🔄 Setting facility data to Firestore...');
          }

          // Set facility data with better error handling
          await ref.set(facilityData, SetOptions(merge: false));

          if (kDebugMode) {
            _facilityServiceDebugLog('✅ Facility data set successfully: ${ref.id}');
            _facilityServiceDebugLog('🔄 Verifying facility was created...');
          }

          // Verify the facility was actually created
          final doc = await ref.get();
          if (!doc.exists) {
            throw Exception('Facility was not created successfully');
          }

          if (kDebugMode) {
            _facilityServiceDebugLog('Facility created and verified successfully: ${ref.id}');
          }

          return ref.id;
        } catch (e) {
          if (kDebugMode) {
            _facilityServiceDebugLog('❌ Error creating facility: $e');
            if (e.toString().contains('permission-denied')) {
              _facilityServiceDebugLog('🚨 PERMISSION DENIED: Check Firestore security rules');
            }
          }
          rethrow;
        }
      }

  /// Check if user can create a facility based on subscription status
  static _CanCreateFacilityResult _canCreateFacility(
    FacilityCreatorAccountModel account,
    int currentFacilityCount,
  ) {
    // First facility is always allowed (will be prompted for subscription after creation)
    if (currentFacilityCount == 0) {
      return _CanCreateFacilityResult(allowed: true);
    }

    // Active subscription: unlimited facilities
    if (account.hasActiveSubscription) {
      return _CanCreateFacilityResult(allowed: true);
    }

    // Trial status: check if trial expired, then check limits
    if (account.hasTrial) {
      // If trial expired, block facility creation
      if (account.isTrialExpired) {
        return _CanCreateFacilityResult(
          allowed: false,
          reason: 'Your trial has expired. Please subscribe to continue creating facilities.',
        );
      }
      // Trial still active: only 1 facility allowed
      if (currentFacilityCount >= 1) {
        return _CanCreateFacilityResult(
          allowed: false,
          reason: 'Trial users can only create 1 facility. Please subscribe to create additional facilities.',
        );
      }
      return _CanCreateFacilityResult(allowed: true);
    }

    // Past due: check grace period (7 days)
    if (account.isSubscriptionPastDue) {
      if (account.canAccessPlatform) {
        // Still in grace period
        return _CanCreateFacilityResult(
          allowed: false,
          reason: 'Your subscription is past due. Please update your payment method to create additional facilities.',
        );
      } else {
        // Grace period expired
        return _CanCreateFacilityResult(
          allowed: false,
          reason: 'Your subscription grace period has expired. Please reactivate your subscription to continue.',
        );
      }
    }

    // Cancelled or unpaid: subscription required
    return _CanCreateFacilityResult(
      allowed: false,
      reason: 'Active subscription required to create additional facilities. Please subscribe to continue.',
    );
  }

  // Fix existing facilities that might be missing the active field
  // Legacy method - redirect to new backfill
  static Future<void> fixExistingFacilities() async {
    await runBackfillIfNeeded();
  }

  // Get user's facilities (owner-scoped query)
  static Future<List<FacilityModel>> getUserFacilities({
    bool includeArchived = false,
    bool forceRefresh = false,
  }) async {
    try {
      final user = _auth.currentUser;
      if (user == null) {
        throw Exception('Not signed in');
      }

      final cacheFresh = _cachedFacilities != null &&
          _lastFacilitiesFetch != null &&
          DateTime.now().difference(_lastFacilitiesFetch!) < _facilityCacheTtl;

      if (!includeArchived && !forceRefresh && cacheFresh) {
        // #region agent log
        DebugLogger.log(
          hypothesisId: 'H3',
          location: 'facility_service.dart:getUserFacilities',
          message: 'Returning facilities from cache',
          data: {'count': _cachedFacilities?.length ?? 0},
        );
        // #endregion
        return _cachedFacilities!;
      }

      if (kDebugMode) {
        _facilityServiceDebugLog('🔄 Getting facilities for owner: ${user.uid}');
      }

      // Fix existing facilities that might be missing the active field
      await fixExistingFacilities();

      // Try ordered query first, fall back to unordered if index is building
      QuerySnapshot snapshot;
      try {
        Query query = _firestore
            .collection('facilities')
            .where('ownerUid', isEqualTo: user.uid);  // ✅ REQUIRED by Firestore rules
        
        if (!includeArchived) {
          query = query.where('active', isEqualTo: true);
        }
        
        query = query.orderBy('active').orderBy('name');
        
        snapshot = await query.get();
      } catch (orderingError) {
        if (orderingError.toString().contains('failed-precondition') && orderingError.toString().contains('index')) {
          if (kDebugMode) {
            _facilityServiceDebugLog('📋 INDEX BUILDING: Using fallback unordered query...');
          }
          // Fallback to unordered query
          Query fallbackQuery = _firestore
              .collection('facilities')
              .where('ownerUid', isEqualTo: user.uid);
          
          if (!includeArchived) {
            fallbackQuery = fallbackQuery.where('active', isEqualTo: true);
          }
          
          snapshot = await fallbackQuery.get();
        } else {
          rethrow;
        }
      }

      if (kDebugMode) {
        _facilityServiceDebugLog('✅ Successfully retrieved ${snapshot.docs.length} facilities');
      }

      final owned = snapshot.docs
          .map(
            (doc) => FacilityModel.fromFirestore(doc)
                .copyWith(currentUserOwnsFacility: true),
          )
          .toList();

      final ownedIds = owned.map((f) => f.id).toSet();
      final fromRoles = await _facilitiesFromActiveUserRoles(
        user.uid,
        includeArchived: includeArchived,
        ownedIds: ownedIds,
      );

      final byId = <String, FacilityModel>{};
      for (final f in owned) {
        byId[f.id] = f;
      }
      for (final f in fromRoles) {
        byId.putIfAbsent(
          f.id,
          () => f.copyWith(currentUserOwnsFacility: false),
        );
      }
      final facilities = byId.values.toList()
        ..sort((a, b) => a.name.compareTo(b.name));

      if (!includeArchived) {
        _cachedFacilities = facilities;
        _lastFacilitiesFetch = DateTime.now();
      }
      // #region agent log
      DebugLogger.log(
        hypothesisId: 'H3',
        location: 'facility_service.dart:getUserFacilities',
        message: 'Facilities fetched',
        data: {'count': facilities.length, 'includeArchived': includeArchived, 'forceRefresh': forceRefresh},
      );
      // #endregion
      
      return facilities;
    } catch (e) {
      if (kDebugMode) {
        _facilityServiceDebugLog('❌ Error getting user facilities: $e');
        if (e.toString().contains('permission-denied')) {
          _facilityServiceDebugLog('🚨 PERMISSION DENIED: Check Firestore security rules for facilities collection');
        }
      }
      
      return [];
    }
  }

  // Real-time stream for ACTIVE facilities only
  static Stream<List<FacilityModel>> getUserFacilitiesStream({bool includeArchived = false}) {
    if (includeArchived) {
      return getUserArchivedFacilitiesStream();
    } else {
      return getUserActiveFacilitiesStream();
    }
  }

  static Stream<List<FacilityModel>> getFacilitiesForUserStream() {
    final controller = StreamController<List<FacilityModel>>.broadcast();
    StreamSubscription? ownedSub;
    StreamSubscription? rolesSub;
    final facilityMap = <String, FacilityModel>{};
    var ownerFacilityIds = <String>{};
    var roleFacilityIds = <String>{};

    void emit() {
      if (controller.isClosed) return;
      final list = facilityMap.values
          .map(
            (f) => f.copyWith(
              currentUserOwnsFacility: ownerFacilityIds.contains(f.id),
            ),
          )
          .toList()
        ..sort((a, b) => a.name.compareTo(b.name));
      controller.add(list);
    }

    Future<void> syncRoleFacilities(QuerySnapshot<Map<String, dynamic>> snapshot) async {
      final ids = snapshot.docs
          .map((doc) => doc.data()['facilityId'] as String?)
          .where((id) => id != null && id.isNotEmpty)
          .cast<String>()
          .toSet();
      roleFacilityIds = ids;

      final missing = ids.where((id) => !facilityMap.containsKey(id)).toList();
      if (missing.isNotEmpty) {
        final futures = missing
            .map((id) => _firestore.collection('facilities').doc(id).get())
            .toList();
        final results = await Future.wait(futures);
        for (final doc in results) {
          if (!doc.exists) continue;
          final model = FacilityModel.fromFirestore(doc);
          if (model.active) {
            facilityMap[model.id] = model;
          }
        }
      }

      final toRemove = facilityMap.keys
          .where((id) => !ownerFacilityIds.contains(id) && !roleFacilityIds.contains(id))
          .toList();
      for (final id in toRemove) {
        facilityMap.remove(id);
      }
      emit();
    }

    void syncOwnedFacilities(QuerySnapshot<Map<String, dynamic>> snapshot) {
      ownerFacilityIds = snapshot.docs.map((doc) => doc.id).toSet();
      for (final doc in snapshot.docs) {
        final model = FacilityModel.fromFirestore(doc);
        facilityMap[model.id] = model;
      }
      final toRemove = facilityMap.keys
          .where((id) => !ownerFacilityIds.contains(id) && !roleFacilityIds.contains(id))
          .toList();
      for (final id in toRemove) {
        facilityMap.remove(id);
      }
      emit();
    }

    void start() {
      final user = _auth.currentUser;
      if (user == null) {
        controller.add([]);
        controller.close();
        return;
      }

      ownedSub = _firestore
          .collection('facilities')
          .where('active', isEqualTo: true)
          .where('ownerUid', isEqualTo: user.uid)
          .snapshots()
          .listen(syncOwnedFacilities, onError: controller.addError);

      rolesSub = _firestore
          .collection(PermissionService.userRolesCollection)
          .where('userId', isEqualTo: user.uid)
          .where('isActive', isEqualTo: true)
          .snapshots()
          .listen(syncRoleFacilities, onError: controller.addError);
    }

    controller.onListen = start;
    controller.onCancel = () async {
      await ownedSub?.cancel();
      await rolesSub?.cancel();
      if (!controller.isClosed) {
        await controller.close();
      }
    };

    return controller.stream;
  }

  // Real-time stream for ACTIVE facilities only (owned + invited via user_roles)
  static Stream<List<FacilityModel>> getUserActiveFacilitiesStream() {
    final user = _auth.currentUser;
    if (user == null) {
      throw Exception('Not signed in');
    }
    if (kDebugMode) {
      _facilityServiceDebugLog('🔄 ACTIVE facilities stream (owned + roles): ${user.uid}');
    }
    return getFacilitiesForUserStream();
  }

  // Real-time stream for ARCHIVED facilities only
  static Stream<List<FacilityModel>> getUserArchivedFacilitiesStream() {
    try {
      final user = _auth.currentUser;
      if (user == null) {
        throw Exception('Not signed in');
      }

      if (kDebugMode) {
        _facilityServiceDebugLog('🔄 Setting up ARCHIVED facilities stream for owner: ${user.uid}');
      }

      Query query = _firestore
          .collection('facilities')
          .where('ownerUid', isEqualTo: user.uid)
          .where('active', isEqualTo: false);
      
      // Try ordered query, fall back to unordered if index is building
      try {
        query = query.orderBy('archivedAt', descending: true);
      } catch (orderingError) {
        if (kDebugMode) {
          _facilityServiceDebugLog('⚠️ Ordered query not available, using unordered: $orderingError');
        }
      }

      return query.snapshots().map((snapshot) {
        final facilities = snapshot.docs.map((doc) {
          return FacilityModel.fromFirestore(doc);
        }).toList();

        // Sort in memory by name if we used fallback query
        facilities.sort((a, b) => a.name.compareTo(b.name));

        if (kDebugMode) {
          _facilityServiceDebugLog('📡 Stream update: ${facilities.length} ARCHIVED facilities for owner: ${user.uid}');
        }

        return facilities;
      });
    } catch (e) {
      if (kDebugMode) {
        _facilityServiceDebugLog('❌ Error setting up archived facilities stream: $e');
      }
      rethrow;
    }
  }

  // Get a specific facility by ID
  static Future<FacilityModel?> getFacility(String facilityId) async {
    try {
      final user = _auth.currentUser;
      if (user == null) {
        throw Exception('Not signed in');
      }

      final doc = await _firestore.collection('facilities').doc(facilityId).get();
      
      if (!doc.exists) {
        return null;
      }

      final raw = doc.data();
      if (raw == null) return null;
      final data = Map<String, dynamic>.from(raw);
      final allowed = await _userMayReadFacilityDoc(
        facilityId: facilityId,
        data: data,
        user: user,
      );
      if (!allowed) {
        if (kDebugMode) {
          _facilityServiceDebugLog('❌ User ${user.uid} cannot read facility $facilityId');
        }
        return null;
      }

      return FacilityModel.fromFirestore(doc);
    } catch (e) {
      if (kDebugMode) {
        _facilityServiceDebugLog('❌ Error getting facility: $e');
      }
      return null;
    }
  }

  // Update facility
  /// Firestore field paths that set only the given billing settings, leaving
  /// every other key in the facility's billingSettings map as it was.
  static Map<String, dynamic> billingSettingsFieldUpdates(
          Map<String, dynamic> settings) =>
      {
        for (final entry in settings.entries)
          'billingSettings.${entry.key}': entry.value,
      };

  static Future<void> updateFacility({
    required String facilityId,
    String? name,
    String? logoUrl,
    String? address,
    String? mailingAddress, // '' clears it
    String? statementMessage, // '' clears it
    String? phone,
    String? email,
    String? timeZone,
    Map<String, dynamic>? businessHours,
    Map<String, dynamic>? gateHours,
    Map<String, dynamic>? billingSettings,
    Map<String, dynamic>? insuranceSettings,
    String? paymentProcessor, // 'stripe' | 'square'
    int? totalUnits, // Physical capacity - when provided, updates facility capacity
  }) async {
    try {
      final user = _auth.currentUser;
      if (user == null) {
        throw Exception('Not signed in');
      }

      // First verify ownership
      final facility = await getFacility(facilityId);
      if (facility == null) {
        throw Exception('Facility not found or access denied');
      }

      if (kDebugMode) {
        _facilityServiceDebugLog('🔄 Updating facility: $facilityId');
      }

      final updateData = <String, dynamic>{
        'updatedAt': FieldValue.serverTimestamp(),
      };

      if (name != null) updateData['name'] = name;
      if (logoUrl != null) {
        updateData['logoUrl'] = logoUrl.isEmpty ? FieldValue.delete() : logoUrl;
      }
      if (address != null) updateData['address'] = address;
      if (mailingAddress != null) {
        updateData['mailingAddress'] =
            mailingAddress.isEmpty ? FieldValue.delete() : mailingAddress;
      }
      if (statementMessage != null) {
        updateData['statementMessage'] =
            statementMessage.isEmpty ? FieldValue.delete() : statementMessage;
      }
      if (phone != null) updateData['phone'] = phone;
      if (email != null) updateData['email'] = email;
      if (timeZone != null) updateData['timeZone'] = timeZone;
      if (businessHours != null) updateData['businessHours'] = businessHours;
      if (gateHours != null) updateData['gateHours'] = gateHours;
      // Merged key by key: billingSettings is shared by several screens
      // (Edit Facility, delinquency rules) and by server settings such as
      // admin/move-in fees and payment reminders. Writing the map whole let
      // each screen silently erase every key it did not know about.
      if (billingSettings != null) {
        updateData.addAll(billingSettingsFieldUpdates(billingSettings));
      }
      if (insuranceSettings != null) updateData['insuranceSettings'] = insuranceSettings;
      if (paymentProcessor != null) updateData['paymentProcessor'] = paymentProcessor;
      if (totalUnits != null) {
        if (totalUnits < 1 || totalUnits > kMaxFacilityCapacityUnits) {
          throw Exception(
            'Total units must be between 1 and $kMaxFacilityCapacityUnits.',
          );
        }
        updateData['totalUnits'] = totalUnits;
      }

      await _firestore.collection('facilities').doc(facilityId).update(updateData);

      if (kDebugMode) {
        _facilityServiceDebugLog('✅ Facility updated successfully: $facilityId');
      }
    } catch (e) {
      if (kDebugMode) {
        _facilityServiceDebugLog('❌ Error updating facility: $e');
      }
      rethrow;
    }
  }

  // Archive facility (soft delete)
  static Future<void> archiveFacility(String facilityId) async {
    try {
      final user = _auth.currentUser;
      if (user == null) {
        throw Exception('Not signed in');
      }

      // First verify ownership
      final facility = await getFacility(facilityId);
      if (facility == null) {
        throw Exception('Facility not found or access denied');
      }

      if (kDebugMode) {
        _facilityServiceDebugLog('🔄 Archiving facility: $facilityId');
      }

      await _firestore.collection('facilities').doc(facilityId).update({
        'active': false,
        'archivedAt': FieldValue.serverTimestamp(),
        'archivedByUid': user.uid,
        'updatedAt': FieldValue.serverTimestamp(),
      });

      // Keep account.facilityIds in sync so subscription/billing reflects actual facilities
      bool accountSyncOk = false;
      try {
        final account = await FacilityCreatorAccountService.getOrCreateAccountForCurrentUser();
        await FacilityCreatorAccountService.removeFacilityFromAccount(
          accountId: account.accountId,
          facilityId: facilityId,
        );
        accountSyncOk = true;
      } catch (e) {
        if (kDebugMode) {
          _facilityServiceDebugLog('⚠️ Could not remove facility from account (archived anyway): $e');
        }
      }
      // Fallback: server-side reconcile overwrites facilityIds from actual facilities
      if (!accountSyncOk) {
        try {
          await FacilityCreatorAccountService.callReconcileAccountFacilityIds();
        } catch (_) {}
      }

      if (kDebugMode) {
        _facilityServiceDebugLog('✅ Facility archived successfully: $facilityId');
      }
    } catch (e) {
      if (kDebugMode) {
        _facilityServiceDebugLog('❌ Error archiving facility: $e');
      }
      rethrow;
    }
  }

  // Soft delete facility (alias for archive)
  static Future<void> softDeleteFacility(String facilityId) async {
    return await archiveFacility(facilityId);
  }

  // Restore facility (unarchive)
  static Future<void> restoreFacility(String facilityId) async {
    try {
      final user = _auth.currentUser;
      if (user == null) {
        throw Exception('Not signed in');
      }

      // First verify ownership
      final facility = await getFacility(facilityId);
      if (facility == null) {
        throw Exception('Facility not found or access denied');
      }

      if (kDebugMode) {
        _facilityServiceDebugLog('🔄 Restoring facility: $facilityId');
      }

      await _firestore.collection('facilities').doc(facilityId).update({
        'active': true,
        'restoredAt': FieldValue.serverTimestamp(),
        'restoredByUid': user.uid,
        'updatedAt': FieldValue.serverTimestamp(),
      });

      if (kDebugMode) {
        _facilityServiceDebugLog('✅ Facility restored successfully: $facilityId');
      }
    } catch (e) {
      if (kDebugMode) {
        _facilityServiceDebugLog('❌ Error restoring facility: $e');
      }
      rethrow;
    }
  }

  // Hard delete facility (permanent deletion)
  static Future<void> hardDeleteFacility(String facilityId) async {
    return await deleteFacility(facilityId);
  }

  // Delete facility permanently (hard delete). The deleteFacilityPermanently
  // callable (functions-admin) checks the caller owns it and has just
  // entered the email code, stops its billing, and removes the whole
  // subtree. The app used to delete subcollection by subcollection, carry on
  // past any it couldn't, and then delete the facility doc, leaving tenant
  // records (names, ID numbers, portal codes) behind. [callable] is for tests.
  static Future<void> deleteFacility(
    String facilityId, {
    Future<Object?> Function(Map<String, Object?> payload)? callable,
  }) async {
    if (kDebugMode) {
      _facilityServiceDebugLog('🔄 Deleting facility permanently: $facilityId');
    }
    try {
      await (callable ?? _callDeleteFacilityPermanently)(
          {'facilityId': facilityId});
    } on FirebaseFunctionsException catch (e) {
      if (kDebugMode) {
        _facilityServiceDebugLog('❌ Error deleting facility: ${e.code} ${e.message}');
      }
      throw callableFailure(
        e,
        permissionDenied:
            "Only the facility's owner can delete it. Nothing was deleted.",
        notFound:
            "This facility wasn't found; it may already be deleted. Refresh the list.",
        unreachable: "Couldn't reach the server, so the delete may not have "
            'finished. Refresh the list to see what changed.',
      );
    }
    if (kDebugMode) {
      _facilityServiceDebugLog('✅ Facility deleted permanently: $facilityId');
    }
  }

  static Future<Object?> _callDeleteFacilityPermanently(
      Map<String, Object?> payload) async {
    final result = await FirebaseFunctions.instance
        .httpsCallable(
          'deleteFacilityPermanently',
          options: HttpsCallableOptions(timeout: const Duration(minutes: 9)),
        )
        .call<dynamic>(payload);
    return result.data;
  }

}
