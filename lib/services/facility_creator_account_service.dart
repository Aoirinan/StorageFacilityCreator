import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/foundation.dart';
import '../models/facility_creator_account_model.dart';

/// Service for managing Facility Creator Accounts
class FacilityCreatorAccountService {
  static final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  static final FirebaseAuth _auth = FirebaseAuth.instance;

  /// Create a new Facility Creator Account
  /// This should be called when a user first signs up or subscribes
  static Future<String> createAccount({
    required String ownerUid,
    required String ownerEmail,
    required String ownerName,
  }) async {
    try {
      final user = _auth.currentUser;
      if (user == null || user.uid != ownerUid) {
        throw Exception('Not authenticated or UID mismatch');
      }

      if (kDebugMode) {
        print('🔄 Creating Facility Creator Account for: $ownerEmail');
      }

      // Check if account already exists
      final existingAccount = await getAccountByOwnerUid(ownerUid);
      if (existingAccount != null) {
        if (kDebugMode) {
          print('⚠️ Account already exists for user: $ownerUid');
        }
        return existingAccount.accountId;
      }

      final now = DateTime.now();
      final accountRef = _firestore.collection('facilityCreatorAccounts').doc();

      final accountData = {
        'ownerUid': ownerUid,
        'ownerEmail': ownerEmail.toLowerCase(),
        'ownerName': ownerName,
        'subscriptionStatus': SubscriptionStatus.unpaid.name, // Start as unpaid - user must choose trial or subscribe
        'stripeSubscriptionId': null,
        'stripeCustomerId': null,
        'subscriptionCurrentPeriodStart': null,
        'subscriptionCurrentPeriodEnd': null,
        'subscriptionCancelAtPeriodEnd': false,
        'subscriptionCanceledAt': null,
        'subscriptionTrialEnd': null, // Will be set when trial is started
        'createdAt': Timestamp.fromDate(now),
        'updatedAt': Timestamp.fromDate(now),
        'facilityIds': <String>[],
        'metadata': null,
      };

      await accountRef.set(accountData);

      if (kDebugMode) {
        print('✅ Facility Creator Account created: ${accountRef.id}');
      }

      return accountRef.id;
    } catch (e) {
      if (kDebugMode) {
        print('❌ Error creating Facility Creator Account: $e');
      }
      rethrow;
    }
  }

  /// Get account by owner UID
  static Future<FacilityCreatorAccountModel?> getAccountByOwnerUid(String ownerUid) async {
    try {
      final snapshot = await _firestore
          .collection('facilityCreatorAccounts')
          .where('ownerUid', isEqualTo: ownerUid)
          .limit(1)
          .get();

      if (snapshot.docs.isEmpty) {
        return null;
      }

      return FacilityCreatorAccountModel.fromFirestore(snapshot.docs.first);
    } catch (e) {
      if (kDebugMode) {
        print('❌ Error getting account by owner UID: $e');
      }
      return null;
    }
  }

  /// Get account by account ID
  static Future<FacilityCreatorAccountModel?> getAccount(String accountId) async {
    try {
      final doc = await _firestore
          .collection('facilityCreatorAccounts')
          .doc(accountId)
          .get();

      if (!doc.exists) {
        return null;
      }

      return FacilityCreatorAccountModel.fromFirestore(doc);
    } catch (e) {
      if (kDebugMode) {
        print('❌ Error getting account: $e');
      }
      return null;
    }
  }

  /// Get account stream (real-time updates)
  static Stream<FacilityCreatorAccountModel?> getAccountStream(String accountId) {
    return _firestore
        .collection('facilityCreatorAccounts')
        .doc(accountId)
        .snapshots()
        .map((doc) {
      if (!doc.exists) return null;
      return FacilityCreatorAccountModel.fromFirestore(doc);
    });
  }

  /// Update subscription status
  static Future<void> updateSubscriptionStatus({
    required String accountId,
    required SubscriptionStatus status,
    String? stripeSubscriptionId,
    String? stripeCustomerId,
    DateTime? currentPeriodStart,
    DateTime? currentPeriodEnd,
    bool? cancelAtPeriodEnd,
    DateTime? canceledAt,
    DateTime? trialEnd,
  }) async {
    try {
      final user = _auth.currentUser;
      if (user == null) {
        throw Exception('Not authenticated');
      }

      // Verify user owns this account
      final account = await getAccount(accountId);
      if (account == null || account.ownerUid != user.uid) {
        throw Exception('Account not found or access denied');
      }

      if (kDebugMode) {
        print('🔄 Updating subscription status for account: $accountId');
      }

      final updates = <String, dynamic>{
        'subscriptionStatus': status.name,
        'updatedAt': Timestamp.fromDate(DateTime.now()),
      };

      if (stripeSubscriptionId != null) {
        updates['stripeSubscriptionId'] = stripeSubscriptionId;
      }
      if (stripeCustomerId != null) {
        updates['stripeCustomerId'] = stripeCustomerId;
      }
      if (currentPeriodStart != null) {
        updates['subscriptionCurrentPeriodStart'] = Timestamp.fromDate(currentPeriodStart);
      }
      if (currentPeriodEnd != null) {
        updates['subscriptionCurrentPeriodEnd'] = Timestamp.fromDate(currentPeriodEnd);
      }
      if (cancelAtPeriodEnd != null) {
        updates['subscriptionCancelAtPeriodEnd'] = cancelAtPeriodEnd;
      }
      if (canceledAt != null) {
        updates['subscriptionCanceledAt'] = Timestamp.fromDate(canceledAt);
      }
      if (trialEnd != null) {
        updates['subscriptionTrialEnd'] = Timestamp.fromDate(trialEnd);
      }

      await _firestore
          .collection('facilityCreatorAccounts')
          .doc(accountId)
          .update(updates);

      if (kDebugMode) {
        print('✅ Subscription status updated: $status');
      }
    } catch (e) {
      if (kDebugMode) {
        print('❌ Error updating subscription status: $e');
      }
      rethrow;
    }
  }

  /// Add facility to account
  static Future<void> addFacilityToAccount({
    required String accountId,
    required String facilityId,
  }) async {
    try {
      final user = _auth.currentUser;
      if (user == null) {
        throw Exception('Not authenticated');
      }

      // Verify user owns this account
      final account = await getAccount(accountId);
      if (account == null || account.ownerUid != user.uid) {
        throw Exception('Account not found or access denied');
      }

      if (account.facilityIds.contains(facilityId)) {
        if (kDebugMode) {
          print('⚠️ Facility already in account');
        }
        return;
      }

      final updatedFacilityIds = [...account.facilityIds, facilityId];

      await _firestore
          .collection('facilityCreatorAccounts')
          .doc(accountId)
          .update({
        'facilityIds': updatedFacilityIds,
        'updatedAt': Timestamp.fromDate(DateTime.now()),
      });

      // Also update the facility to link to account
      await _firestore
          .collection('facilities')
          .doc(facilityId)
          .update({
        'facilityCreatorAccountId': accountId,
        'updatedAt': Timestamp.fromDate(DateTime.now()),
      });

      // Update Stripe subscription quantity if subscription exists
      await _syncSubscriptionQuantity(accountId);

      if (kDebugMode) {
        print('✅ Facility added to account: $facilityId');
      }
    } catch (e) {
      if (kDebugMode) {
        print('❌ Error adding facility to account: $e');
      }
      rethrow;
    }
  }

  /// Remove facility from account
  static Future<void> removeFacilityFromAccount({
    required String accountId,
    required String facilityId,
  }) async {
    try {
      final user = _auth.currentUser;
      if (user == null) {
        throw Exception('Not authenticated');
      }

      // Verify user owns this account
      final account = await getAccount(accountId);
      if (account == null || account.ownerUid != user.uid) {
        throw Exception('Account not found or access denied');
      }

      final updatedFacilityIds = account.facilityIds.where((id) => id != facilityId).toList();

      await _firestore
          .collection('facilityCreatorAccounts')
          .doc(accountId)
          .update({
        'facilityIds': updatedFacilityIds,
        'updatedAt': Timestamp.fromDate(DateTime.now()),
      });

      // Also update the facility to remove account link
      await _firestore
          .collection('facilities')
          .doc(facilityId)
          .update({
        'facilityCreatorAccountId': FieldValue.delete(),
        'updatedAt': Timestamp.fromDate(DateTime.now()),
      });

      // Update Stripe subscription quantity if subscription exists
      await _syncSubscriptionQuantity(accountId);

      if (kDebugMode) {
        print('✅ Facility removed from account: $facilityId');
      }
    } catch (e) {
      if (kDebugMode) {
        print('❌ Error removing facility from account: $e');
      }
      rethrow;
    }
  }

  /// Check if user has active subscription
  static Future<bool> hasActiveSubscription(String ownerUid) async {
    try {
      final account = await getAccountByOwnerUid(ownerUid);
      if (account == null) {
        return false;
      }
      return account.canAccessPlatform;
    } catch (e) {
      if (kDebugMode) {
        print('❌ Error checking subscription: $e');
      }
      return false;
    }
  }

  /// Get or create account for current user
  /// This is a convenience method that creates an account if it doesn't exist
  static Future<FacilityCreatorAccountModel> getOrCreateAccountForCurrentUser() async {
    final user = _auth.currentUser;
    if (user == null) {
      throw Exception('Not authenticated');
    }

    var account = await getAccountByOwnerUid(user.uid);
    
    if (account == null) {
      // Create new account
      final accountId = await createAccount(
        ownerUid: user.uid,
        ownerEmail: user.email ?? '',
        ownerName: user.displayName ?? 'Facility Creator',
      );
      account = await getAccount(accountId);
      if (account == null) {
        throw Exception('Failed to create account');
      }
    }

    return account;
  }

  /// Sync subscription quantity with current facility count
  /// This should be called whenever facilities are added or removed
  static Future<void> _syncSubscriptionQuantity(String accountId) async {
    try {
      final account = await getAccount(accountId);
      if (account == null || account.stripeSubscriptionId == null) {
        // No subscription to update
        return;
      }

      final functions = FirebaseFunctions.instance;
      final callable = functions.httpsCallable('updateSubscriptionQuantity');
      
      await callable.call(<String, dynamic>{
        'accountId': accountId,
      });

      if (kDebugMode) {
        print('✅ Subscription quantity synced for account: $accountId');
      }
    } catch (e) {
      if (kDebugMode) {
        print('⚠️ Warning: Could not sync subscription quantity: $e');
      }
      // Don't fail facility operations if subscription sync fails
    }
  }
}

