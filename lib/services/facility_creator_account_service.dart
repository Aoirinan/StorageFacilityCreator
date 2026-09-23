import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/foundation.dart';
import '../models/facility_creator_account_model.dart';
import '../models/facility_model.dart';
import 'package:sfcapp/services/permission_service.dart';
import 'referral_program_service.dart';

/// Thrown by [FacilityCreatorAccountService.getOrCreateAccountForCurrentUser]
/// for invited staff, who work in the owner's account and have none of their
/// own.
class InvitedStaffAccountException implements Exception {
  const InvitedStaffAccountException();

  @override
  String toString() =>
      "This login is a team member at another owner's facility, so it has no "
      'owner account of its own.';
}

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

      // Check if account already exists. The throwing read: a failed read
      // came back as "none" and this wrote a duplicate account.
      final existingAccount = await getAccountByOwnerUidOrThrow(ownerUid);
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
        'subscriptionStatus': SubscriptionStatus.pendingApproval.name, // Awaiting admin approval before trial starts
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

  /// Get account by owner UID. Null when there is no account, and also when
  /// the read fails; use [getAccountByOwnerUidOrThrow] where those differ.
  static Future<FacilityCreatorAccountModel?> getAccountByOwnerUid(String ownerUid) async {
    try {
      return await getAccountByOwnerUidOrThrow(ownerUid);
    } catch (e) {
      if (kDebugMode) {
        print('❌ Error getting account by owner UID: $e');
      }
      return null;
    }
  }

  /// [getAccountByOwnerUid] that lets a failed read throw, so null only ever
  /// means "no account". The access check needs the difference: it lets an
  /// owner with no account yet through, and must not do that on a failed read.
  ///
  /// When the owner has more than one account, [preferredOwnerAccount] picks.
  /// [readOwnerAccounts] replaces the Firestore read, for tests only.
  static Future<FacilityCreatorAccountModel?> getAccountByOwnerUidOrThrow(
    String ownerUid, {
    Future<List<FacilityCreatorAccountModel>> Function(String ownerUid)? readOwnerAccounts,
  }) async {
    final accounts = await (readOwnerAccounts ?? _readOwnerAccounts)(ownerUid);
    return preferredOwnerAccount(accounts);
  }

  static Future<List<FacilityCreatorAccountModel>> _readOwnerAccounts(
      String ownerUid) async {
    // Not limit(1): which of several docs that returned was up to Firestore.
    // The bound only stops a runaway read; one per owner is the intent.
    final snapshot = await _firestore
        .collection('facilityCreatorAccounts')
        .where('ownerUid', isEqualTo: ownerUid)
        .limit(20)
        .get();
    return snapshot.docs.map(FacilityCreatorAccountModel.fromFirestore).toList();
  }

  /// The account to use for an owner with [accounts]: any that is not
  /// pendingApproval before one that is, then the oldest (the original, which
  /// is the one a super admin approved, billed or suspended), then by id so
  /// the answer never depends on read order. Null when there are none.
  ///
  /// There should only ever be one, but getOrCreateAccountForCurrentUser used
  /// to create a second, pendingApproval account whenever its read failed,
  /// and the lookup took whichever doc Firestore returned first: a paying
  /// owner could be sent to /pending-approval on that duplicate.
  @visibleForTesting
  static FacilityCreatorAccountModel? preferredOwnerAccount(
      List<FacilityCreatorAccountModel> accounts) {
    if (accounts.isEmpty) return null;
    final sorted = [...accounts]..sort((a, b) {
        final byPending =
            (a.isPendingApproval ? 1 : 0).compareTo(b.isPendingApproval ? 1 : 0);
        if (byPending != 0) return byPending;
        final byAge = a.createdAt.compareTo(b.createdAt);
        if (byAge != 0) return byAge;
        return a.accountId.compareTo(b.accountId);
      });
    return sorted.first;
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

      // Both sides of the link are written by a callable, not from here.
      // `facilities/{id}.facilityCreatorAccountId` is backend-only: entitlement
      // is resolved by reading it and checking the named account's
      // subscription, without checking who owns that account, so a
      // client-writable link would be a free premium subscription. The
      // callable does the same ownership check this method used to rely on the
      // rules for, and then writes both documents.
      final referralBy = account.referredByAccountId?.trim();
      await FirebaseFunctions.instance
          .httpsCallable('linkFacilityToAccount')
          .call<Map<String, dynamic>>({
        'accountId': accountId,
        'facilityId': facilityId,
        if (referralBy != null && referralBy.isNotEmpty)
          'platformReferralReferredByAccountId': referralBy,
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

  /// Reconcile account.facilityIds with actual active facilities only.
  /// Removes orphaned IDs from deleted/archived facilities and syncs Stripe quantity.
  static Future<bool> reconcileFacilityIds({
    required String accountId,
    required List<String> actualFacilityIds,
  }) async {
    try {
      final user = _auth.currentUser;
      if (user == null) {
        throw Exception('Not authenticated');
      }

      final account = await getAccount(accountId);
      if (account == null || account.ownerUid != user.uid) {
        throw Exception('Account not found or access denied');
      }

      final current = account.facilityIds.toSet();
      final actual = actualFacilityIds.toSet();
      if (current.length == actual.length && current.containsAll(actual)) {
        if (kDebugMode) {
          print('✅ Facility IDs already in sync, skip reconcile');
        }
        return false;
      }

      await _firestore
          .collection('facilityCreatorAccounts')
          .doc(accountId)
          .update({
        'facilityIds': actualFacilityIds,
        'updatedAt': Timestamp.fromDate(DateTime.now()),
      });

      await _syncSubscriptionQuantity(accountId);

      if (kDebugMode) {
        print('✅ Reconciled facilityIds: ${current.length} → ${actualFacilityIds.length}');
      }
      return true;
    } catch (e) {
      if (kDebugMode) {
        print('❌ Error reconciling facility IDs: $e');
      }
      rethrow;
    }
  }

  /// The platform-access rule for an account already in hand: a billing-exempt
  /// account, account-level access, or any facility linked to the account that
  /// has an active per-facility platform subscription or is billing-exempt.
  /// [facilities] null means "account only".
  ///
  /// billingExempt is set only by a super admin (the rules refuse it from
  /// owners) and means "never locked out", which is how the route guard and
  /// the subscription banner already treat it; the sidebar lock and the lock
  /// overlay ignored it, and every check ignored it on a facility.
  ///
  /// A suspended account gets nothing from its facilities: suspension is a
  /// super admin's decision about the account, and a linked facility's own
  /// subscription or exemption used to let it straight back in. Only an
  /// exempt account (also a super admin's decision) overrides it.
  static bool accountGrantsPlatformAccess(
    FacilityCreatorAccountModel account, {
    List<FacilityModel>? facilities,
  }) {
    if (account.billingExempt) return true;
    if (account.suspended) return false;
    if (account.canAccessPlatform) return true;
    if (facilities == null) return false;
    final linked = facilities.where((f) => f.facilityCreatorAccountId == account.accountId);
    return linked.any((f) => f.billingExempt || f.hasActivePlatformSubscription);
  }

  /// Check if user has active subscription (account-level OR any per-facility platform sub)
  /// Pass [facilities] to avoid circular import with FacilityService; if null, only checks account.
  static Future<bool> hasActiveSubscription(
    String ownerUid, {
    List<FacilityModel>? facilities,
  }) async {
    try {
      final account = await getAccountByOwnerUid(ownerUid);
      if (account == null) {
        return false;
      }
      return accountGrantsPlatformAccess(account, facilities: facilities);
    } catch (e) {
      if (kDebugMode) {
        print('❌ Error checking subscription: $e');
      }
      return false;
    }
  }

  /// Get or create account for current user
  /// This is a convenience method that creates an account if it doesn't exist
  ///
  /// Throws [InvitedStaffAccountException] instead of creating one for invited
  /// staff (see [ensureAccountFor]), unless [createForInvitedStaff]: pass it
  /// only where the user is creating a facility of their own.
  static Future<FacilityCreatorAccountModel> getOrCreateAccountForCurrentUser({
    bool createForInvitedStaff = false,
  }) async {
    final user = _auth.currentUser;
    if (user == null) {
      throw Exception('Not authenticated');
    }

    final account = await ensureAccountFor(
      user,
      createForInvitedStaff: createForInvitedStaff,
    );
    if (account == null) {
      throw const InvitedStaffAccountException();
    }

    Future.microtask(() => ReferralProgramService.syncForCurrentUser());

    return account;
  }

  /// [getOrCreateAccountForCurrentUser] for screens that only make sure an
  /// owner has an account before loading: null for invited staff, who have
  /// none and must not be given one.
  static Future<FacilityCreatorAccountModel?> ensureAccountForCurrentUser() async {
    final user = _auth.currentUser;
    if (user == null) {
      throw Exception('Not authenticated');
    }
    final account = await ensureAccountFor(user);
    if (account != null) {
      unawaited(Future.microtask(() => ReferralProgramService.syncForCurrentUser()));
    }
    return account;
  }

  /// [user]'s account, created when they have none, or null for invited staff
  /// unless [createForInvitedStaff].
  ///
  /// Every read throws on failure, so a failed read never creates anything:
  /// the old lookup turned a failed read into "no account" and created a
  /// second, pendingApproval account for owners who already had one.
  ///
  /// Invited staff (active roles, no facility of their own) were given a
  /// pendingApproval account by the first screen that called this, and the
  /// route guard then held them on /pending-approval.
  ///
  /// The optional arguments replace the Firestore reads and the create, for
  /// tests only.
  @visibleForTesting
  static Future<FacilityCreatorAccountModel?> ensureAccountFor(
    User user, {
    bool createForInvitedStaff = false,
    Future<FacilityCreatorAccountModel?> Function(String uid)? readAccount,
    Future<bool> Function(String uid)? isInvitedStaffOnly,
    Future<FacilityCreatorAccountModel> Function(User user)? create,
  }) async {
    final existing = await (readAccount ?? getAccountByOwnerUidOrThrow)(user.uid);
    if (existing != null) return existing;

    if (!createForInvitedStaff &&
        await (isInvitedStaffOnly ?? _isInvitedStaffOnly)(user.uid)) {
      return null;
    }
    return (create ?? _createAccountFor)(user);
  }

  /// Whether [uid] has an active role at a facility and owns none. Owners can
  /// have role rows too (an owner row per facility), hence the second read.
  static Future<bool> _isInvitedStaffOnly(String uid) async {
    final results = await Future.wait([
      _firestore
          .collection(PermissionService.userRolesCollection)
          .where('userId', isEqualTo: uid)
          .where('isActive', isEqualTo: true)
          .limit(1)
          .get(),
      _firestore
          .collection('facilities')
          .where('ownerUid', isEqualTo: uid)
          .limit(1)
          .get(),
    ]);
    return results[0].docs.isNotEmpty && results[1].docs.isEmpty;
  }

  static Future<FacilityCreatorAccountModel> _createAccountFor(User user) async {
    final accountId = await createAccount(
      ownerUid: user.uid,
      ownerEmail: user.email ?? '',
      ownerName: user.displayName ?? 'Facility Creator',
    );
    final account = await getAccount(accountId);
    if (account == null) {
      throw Exception('Failed to create account');
    }
    return account;
  }

  /// Server-side reconcile: fix facilityIds from actual active facilities + sync Stripe.
  /// Call when loading subscription or after delete/archive. Source of truth.
  static Future<Map<String, dynamic>?> callReconcileAccountFacilityIds() async {
    try {
      final functions = FirebaseFunctions.instance;
      final callable = functions.httpsCallable('reconcileAccountFacilityIds');
      final result = await callable.call<Map<String, dynamic>>(<String, dynamic>{});
      final data = result.data;
      if (data == null) return null;
      return Map<String, dynamic>.from(data);
    } catch (e) {
      if (kDebugMode) {
        print('❌ callReconcileAccountFacilityIds failed: $e');
      }
      rethrow;
    }
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

