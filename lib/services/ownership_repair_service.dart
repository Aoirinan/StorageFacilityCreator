import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';

/// Service to automatically repair ownership issues after subscription
/// This fixes cases where facility/account ownership gets out of sync
class OwnershipRepairService {
  static final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  static final FirebaseAuth _auth = FirebaseAuth.instance;

  /// Check and repair ownership on app start / login
  static Future<void> checkAndRepairOwnership() async {
    try {
      final user = _auth.currentUser;
      if (user == null) return;

      final currentUid = user.uid;
      final userEmail = user.email?.toLowerCase();

      if (kDebugMode) {
        print('🔧 [OwnershipRepair] Checking ownership for: $userEmail (UID: $currentUid)');
      }

      // 1. Check facilityCreatorAccount
      final accountSnapshot = await _firestore
          .collection('facilityCreatorAccounts')
          .where('ownerUid', isEqualTo: currentUid)
          .limit(1)
          .get();

      String? accountId;
      if (accountSnapshot.docs.isEmpty && userEmail != null) {
        // Try to find by email
        final accountByEmailSnapshot = await _firestore
            .collection('facilityCreatorAccounts')
            .where('ownerEmail', isEqualTo: userEmail)
            .limit(1)
            .get();

        if (accountByEmailSnapshot.docs.isNotEmpty) {
          final accountDoc = accountByEmailSnapshot.docs.first;
          accountId = accountDoc.id;
          final accountData = accountDoc.data();
          final oldUid = accountData['ownerUid'];

          if (oldUid != currentUid) {
            if (kDebugMode) {
              print('🔧 [OwnershipRepair] Fixing account ownership: $oldUid -> $currentUid');
            }

            // FIX: Update account ownerUid
            await _firestore.collection('facilityCreatorAccounts').doc(accountId).update({
              'ownerUid': currentUid,
              'updatedAt': FieldValue.serverTimestamp(),
            });

            if (kDebugMode) {
              print('✅ [OwnershipRepair] Account ownership fixed: $accountId');
            }
          }
        }
      } else if (accountSnapshot.docs.isNotEmpty) {
        accountId = accountSnapshot.docs.first.id;
      }

      // 2. Check facilities
      final facilitiesSnapshot = await _firestore
          .collection('facilities')
          .where('ownerUid', isEqualTo: currentUid)
          .where('active', isEqualTo: true)
          .get();

      List<String> fixedFacilityIds = [];
      if (facilitiesSnapshot.docs.isEmpty && userEmail != null) {
        // Try to find facilities by email
        final allFacilitiesSnapshot = await _firestore
            .collection('facilities')
            .where('active', isEqualTo: true)
            .get();

        for (final facilityDoc in allFacilitiesSnapshot.docs) {
          final facilityData = facilityDoc.data();
          final facilityEmail = facilityData['email']?.toString().toLowerCase();
          final oldUid = facilityData['ownerUid'];

          if (facilityEmail == userEmail && oldUid != currentUid) {
            if (kDebugMode) {
              print('🔧 [OwnershipRepair] Fixing facility ownership: ${facilityDoc.id} ($oldUid -> $currentUid)');
            }

            // FIX: Update facility ownerUid
            await _firestore.collection('facilities').doc(facilityDoc.id).update({
              'ownerUid': currentUid,
              'updatedAt': FieldValue.serverTimestamp(),
            });

            fixedFacilityIds.add(facilityDoc.id);
            if (kDebugMode) {
              print('✅ [OwnershipRepair] Facility ownership fixed: ${facilityDoc.id}');
            }
          }
        }
      } else {
        fixedFacilityIds = facilitiesSnapshot.docs.map((doc) => doc.id).toList();
      }

      // 3. Update account.facilityIds if needed
      if (accountId != null && fixedFacilityIds.isNotEmpty) {
        final accountDoc = await _firestore.collection('facilityCreatorAccounts').doc(accountId).get();
        if (accountDoc.exists) {
          final accountData = accountDoc.data();
          final currentFacilityIds = List<String>.from(accountData?['facilityIds'] ?? []);

          fixedFacilityIds.sort();
          currentFacilityIds.sort();

          if (fixedFacilityIds.toString() != currentFacilityIds.toString()) {
            if (kDebugMode) {
              print('🔧 [OwnershipRepair] Syncing account.facilityIds: $currentFacilityIds -> $fixedFacilityIds');
            }

            await _firestore.collection('facilityCreatorAccounts').doc(accountId).update({
              'facilityIds': fixedFacilityIds,
              'updatedAt': FieldValue.serverTimestamp(),
            });

            if (kDebugMode) {
              print('✅ [OwnershipRepair] Account facilityIds synced');
            }
          }
        }
      }

      if (kDebugMode) {
        print('✅ [OwnershipRepair] Ownership check complete - all systems nominal');
      }
    } catch (e, stackTrace) {
      // Don't throw - this is a background repair service
      if (kDebugMode) {
        print('❌ [OwnershipRepair] Error: $e');
        print('❌ [OwnershipRepair] Stack trace: $stackTrace');
      }
    }
  }
}
