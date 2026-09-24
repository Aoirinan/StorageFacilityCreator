import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/foundation.dart';
import '../models/facility_creator_account_model.dart';
import '../models/facility_model.dart';
import 'package:sfcapp/services/error_reporter.dart';
import 'package:sfcapp/services/permission_service.dart';
import 'package:sfcapp/utils/single_flight.dart';
import 'package:sfcapp/utils/verified_email_token.dart';
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

/// What decides whether a user with no account is given one: their ties to
/// facilities (see [FacilityCreatorAccountService.ensureAccountFor]).
@immutable
class AccountTies {
  const AccountTies({
    required this.activeRole,
    required this.ownsFacility,
    required this.pendingInvite,
  });

  /// An active `user_roles` row at any facility (owners have one too).
  final bool activeRole;

  /// A facility whose ownerUid is theirs.
  final bool ownsFacility;

  /// A pending invite addressed to their email.
  final bool pendingInvite;

  /// Works at someone else's facility, or is invited to, and owns none. They
  /// work in the owner's account and must not be given one of their own.
  bool get invitedStaffOnly => (activeRole || pendingInvite) && !ownsFacility;

  /// A genuinely new signup: no role, no facility and no invite anywhere.
  bool get newSignup => !activeRole && !ownsFacility && !pendingInvite;
}

/// When [FacilityCreatorAccountService.ensureAccountFor] may create an
/// account.
enum _Creates { newSignupsOnly, unlessInvitedStaff, always }

/// The route guard's ensure could not accept a new invitee's invites, so
/// they have no role yet.
class _InvitesNotAccepted implements Exception {
  const _InvitesNotAccepted();

  @override
  String toString() => 'Pending invites could not be accepted; will retry.';
}

/// Service for managing Facility Creator Accounts
class FacilityCreatorAccountService {
  static final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  static final FirebaseAuth _auth = FirebaseAuth.instance;

  // Where this service's top-level collections, collection groups, signed-in
  // user and invite fulfilment come from. Firestore, Auth and
  // PermissionService, unless a test points them at fakes so the service's
  // own queries and checks run.
  static CollectionReference<Map<String, dynamic>> Function(String name) _collection =
      _firestoreCollection;
  static Query<Map<String, dynamic>> Function(String name) _collectionGroup =
      _firestoreCollectionGroup;
  static User? Function() _currentUser = _authCurrentUser;
  static Future<bool> Function(User user, String emailLower) _fulfillInvites =
      _permissionServiceFulfillInvites;

  static CollectionReference<Map<String, dynamic>> _firestoreCollection(String name) =>
      _firestore.collection(name);
  static Query<Map<String, dynamic>> _firestoreCollectionGroup(String name) =>
      _firestore.collectionGroup(name);
  static User? _authCurrentUser() => _auth.currentUser;
  static Future<bool> _permissionServiceFulfillInvites(User user, String emailLower) =>
      PermissionService.fulfillPendingInvitesForUser(
        userId: user.uid,
        emailLower: emailLower,
        email: user.email,
        displayName: user.displayName,
      );

  /// Serves [collection], [collectionGroup], [currentUser] and
  /// [fulfillPendingInvites] instead of Firestore, Auth and PermissionService;
  /// null restores them.
  @visibleForTesting
  static void overrideForTesting({
    CollectionReference<Map<String, dynamic>> Function(String name)? collection,
    Query<Map<String, dynamic>> Function(String name)? collectionGroup,
    User? Function()? currentUser,
    Future<bool> Function(User user, String emailLower)? fulfillPendingInvites,
  }) {
    _collection = collection ?? _firestoreCollection;
    _collectionGroup = collectionGroup ?? _firestoreCollectionGroup;
    _currentUser = currentUser ?? _authCurrentUser;
    _fulfillInvites = fulfillPendingInvites ?? _permissionServiceFulfillInvites;
  }

  /// Create a new Facility Creator Account
  /// This should be called when a user first signs up or subscribes
  static Future<String> createAccount({
    required String ownerUid,
    required String ownerEmail,
    required String ownerName,
  }) async {
    try {
      final user = _currentUser();
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
      final accountRef = _collection('facilityCreatorAccounts').doc();

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
    final snapshot = await _collection('facilityCreatorAccounts')
        .where('ownerUid', isEqualTo: ownerUid)
        .limit(20)
        .get();
    return parseOwnerAccounts(snapshot.docs);
  }

  /// Every doc in [docs] that parses. A malformed duplicate (a date that is
  /// not a Timestamp, metadata that is not a map) used to throw for the whole
  /// read, and the guard then sent a paying owner to /subscription on every
  /// navigation. Throws only when none parse, so a real failure still fails.
  @visibleForTesting
  static List<FacilityCreatorAccountModel> parseOwnerAccounts(
      List<DocumentSnapshot<Map<String, dynamic>>> docs) {
    final parsed = <FacilityCreatorAccountModel>[];
    Object? firstError;
    StackTrace? firstStack;
    for (final doc in docs) {
      try {
        parsed.add(FacilityCreatorAccountModel.fromFirestore(doc));
      } catch (e, st) {
        firstError ??= e;
        firstStack ??= st;
        ErrorReporter.reportError(e, st,
            context: 'FacilityCreatorAccountService.parseOwnerAccounts',
            metadata: {'accountId': doc.id});
      }
    }
    if (parsed.isEmpty && firstError != null) {
      Error.throwWithStackTrace(firstError, firstStack!);
    }
    return parsed;
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
      final doc = await _collection('facilityCreatorAccounts')
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

  /// Get or create account for current user
  /// This is a convenience method that creates an account if it doesn't exist
  ///
  /// Throws [InvitedStaffAccountException] instead of creating one for invited
  /// staff (see [ensureAccountFor]), unless [createForInvitedStaff]: pass it
  /// only where the user is creating a facility of their own.
  static Future<FacilityCreatorAccountModel> getOrCreateAccountForCurrentUser({
    bool createForInvitedStaff = false,
  }) async {
    final user = _currentUser();
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
    final user = _currentUser();
    if (user == null) {
      throw Exception('Not authenticated');
    }
    final account = await ensureAccountFor(user);
    if (account != null) {
      unawaited(Future.microtask(() => ReferralProgramService.syncForCurrentUser()));
    }
    return account;
  }

  // What ensureAccountOnce settled this session, per user and mode (see
  // _onceKey): an account found or created, or confirmed as not wanted.
  static final Set<String> _ensuredThisSession = <String>{};

  // When ensureAccountOnce last failed, per user and mode.
  static final Map<String, DateTime> _failedAt = <String, DateTime>{};

  /// How long [ensureAccountOnce] leaves a failure before trying again. The
  /// route guard awaits it on every navigation until it succeeds, so while it
  /// kept failing (offline, a refused write) each click paid the account read,
  /// the staff queries and the failed write again.
  @visibleForTesting
  static const Duration ensureRetryAfter = Duration(seconds: 60);

  static String _onceKey(String uid, {required bool createOnlyForNewSignups}) =>
      createOnlyForNewSignups ? '$uid/new-signups' : uid;

  /// Makes sure [user] has an account if they should (see
  /// [ensureAccountFor]), once per session. Never throws: a failure is
  /// reported, and a call after [ensureRetryAfter] tries again.
  ///
  /// The route guard runs this with [createOnlyForNewSignups] on the first
  /// authenticated load, so a new signup's pendingApproval account is
  /// created, and the onboarding and admin-alert emails it triggers go out,
  /// as soon as they are in the app. It used to happen only when they opened
  /// a screen that created it.
  ///
  /// True the first time it succeeds for [user] in that mode: anything
  /// decided before the account existed or invites were accepted (the
  /// guard's cached answer) is stale.
  static Future<bool> ensureAccountOnce(
    User user, {
    bool createOnlyForNewSignups = false,
    Future<FacilityCreatorAccountModel?> Function(User user)? ensure,
    Duration timeout = const Duration(seconds: 15),
    DateTime Function()? clock,
  }) async {
    final key = _onceKey(user.uid, createOnlyForNewSignups: createOnlyForNewSignups);
    if (_ensuredThisSession.contains(key)) return false;
    final now = clock ?? DateTime.now;
    final failedAt = _failedAt[key];
    if (failedAt != null && now().difference(failedAt) < ensureRetryAfter) {
      return false;
    }
    try {
      final account = await (ensure ??
              (User u) => ensureAccountFor(u, createOnlyForNewSignups: createOnlyForNewSignups))(
          user)
          .timeout(timeout);
      _failedAt.remove(key);
      // An account settles both modes. "None wanted" settles only this one:
      // the route guard leaves an owner who has no account to the screens
      // that create one, as before.
      if (account != null) {
        _ensuredThisSession
            .add(_onceKey(user.uid, createOnlyForNewSignups: !createOnlyForNewSignups));
      }
      return _ensuredThisSession.add(key);
    } catch (e, st) {
      _failedAt[key] = now();
      ErrorReporter.reportError(e, st,
          context: 'FacilityCreatorAccountService.ensureAccountOnce',
          metadata: {'uid': user.uid});
      return false;
    }
  }

  /// For screens that list what the user already has. The account only
  /// matters to the creation flows, so this never holds up or fails the
  /// screen's load: it starts [ensureAccountOnce] and returns. Those screens
  /// used to await the account and, if the read failed, return before
  /// loading their facilities, which left them blank.
  static void ensureAccountInBackground({
    User? Function()? currentUser,
    Future<bool> Function(User user)? ensureOnce,
  }) {
    try {
      final user = (currentUser ?? _currentUser)();
      if (user == null) return;
      unawaited((ensureOnce ?? ensureAccountOnce)(user));
    } catch (e, st) {
      ErrorReporter.reportError(e, st,
          context: 'FacilityCreatorAccountService.ensureAccountInBackground');
    }
  }

  /// Forgets which users were ensured and which failed, e.g. on sign-out.
  /// Exposed for tests.
  @visibleForTesting
  static void resetEnsuredForTesting() {
    _ensuredThisSession.clear();
    _failedAt.clear();
  }

  /// [user]'s account, created when they have none and should have one, or
  /// null when they should not:
  ///
  /// - By default (the screens), anyone but invited staff: a role or a
  ///   pending invite at a facility, and no facility of their own
  ///   ([AccountTies.invitedStaffOnly]). Staff were given a pendingApproval
  ///   account by the first screen that called this, and the route guard
  ///   then held them on /pending-approval.
  /// - [createOnlyForNewSignups] (the route guard): only a genuinely new
  ///   signup ([AccountTies.newSignup]), after accepting the invites
  ///   addressed to their email if they have never had a role or a facility
  ///   (anyone else accepts through the invite's link). An invited signup
  ///   was given an account before their invite was accepted, and an owner
  ///   who already had facilities but no account one they were then locked
  ///   out on; such an owner is left to the screens that create one, as
  ///   before. Throws when a new invitee's invites could not be accepted, so
  ///   [ensureAccountOnce] tries again rather than settling.
  /// - [createForInvitedStaff] (creating a facility of their own): always.
  ///
  /// Every read throws on failure, so a failed read never creates anything:
  /// the old lookup turned a failed read into "no account" and created a
  /// second, pendingApproval account for owners who already had one.
  ///
  /// One run per user at a time: the route guard's first-load ensure and a
  /// screen's could otherwise both read "no account" and both create one.
  ///
  /// The optional arguments replace the Firestore reads and the create, for
  /// tests only.
  @visibleForTesting
  static Future<FacilityCreatorAccountModel?> ensureAccountFor(
    User user, {
    bool createForInvitedStaff = false,
    bool createOnlyForNewSignups = false,
    Future<FacilityCreatorAccountModel?> Function(String uid)? readAccount,
    Future<AccountTies> Function(User user)? readTies,
    Future<FacilityCreatorAccountModel> Function(User user)? create,
  }) async {
    final creates = createForInvitedStaff
        ? _Creates.always
        : createOnlyForNewSignups
            ? _Creates.newSignupsOnly
            : _Creates.unlessInvitedStaff;
    Future<FacilityCreatorAccountModel?> run() => _ensureFlight.run(user.uid, () {
          _inFlightCreates[user.uid] = creates;
          return _ensureAccountFor(
            user,
            creates,
            readAccount: readAccount,
            readTies: readTies,
            create: create,
          );
        });
    final joined = _ensureFlight.isInFlight(user.uid) ? _inFlightCreates[user.uid] : null;
    final account = await run();
    if (account != null || joined == null || joined == creates) return account;
    // Joined another caller's run, which found no account and decided on its
    // own terms (the route guard's, while a screen or a new facility asked):
    // ask again on this caller's, now that it has settled and cannot race a
    // create.
    return run();
  }

  static final SingleFlight<String, FacilityCreatorAccountModel?> _ensureFlight =
      SingleFlight<String, FacilityCreatorAccountModel?>();

  // What the run in _ensureFlight for each uid creates for.
  static final Map<String, _Creates> _inFlightCreates = <String, _Creates>{};

  static Future<FacilityCreatorAccountModel?> _ensureAccountFor(
    User user,
    _Creates creates, {
    Future<FacilityCreatorAccountModel?> Function(String uid)? readAccount,
    Future<AccountTies> Function(User user)? readTies,
    Future<FacilityCreatorAccountModel> Function(User user)? create,
  }) async {
    final existing = await (readAccount ?? getAccountByOwnerUidOrThrow)(user.uid);
    if (existing != null) return existing;

    switch (creates) {
      case _Creates.always:
        break;
      case _Creates.unlessInvitedStaff:
        if ((await (readTies ?? _readTies)(user)).invitedStaffOnly) return null;
      case _Creates.newSignupsOnly:
        // Invites first, so an invited signup is on their facility's team,
        // not mistaken for a new owner, before anything is decided. Only a
        // genuinely new invitee's are accepted this way (see
        // PermissionService.fulfillPendingInvitesForUser).
        final accepted = await _fulfillPendingInvites(user);
        final ties = await (readTies ?? _readTies)(user);
        // An invitee whose invites could not be accepted and who has no role
        // is a failure, not an answer: settling here left them on an empty
        // dashboard for the rest of the session. ensureAccountOnce tries
        // again after ensureRetryAfter.
        if (!accepted && ties.pendingInvite && !ties.activeRole) {
          throw const _InvitesNotAccepted();
        }
        if (!ties.newSignup) return null;
    }
    return (create ?? _createAccountFor)(user);
  }

  static String? _emailLowerOf(User user) {
    final email = user.email?.trim().toLowerCase();
    return email == null || email.isEmpty ? null : email;
  }

  /// Accepts the pending invites addressed to [user]'s email when they are a
  /// genuinely new invitee. Never throws: false when that failed. An invite
  /// left pending still counts in [_readTies], so a failure here cannot turn
  /// an invited signup into a new owner.
  static Future<bool> _fulfillPendingInvites(User user) async {
    final emailLower = _emailLowerOf(user);
    if (emailLower == null) return true;
    try {
      await refreshStaleEmailVerifiedClaim(user);
      return await _fulfillInvites(user, emailLower);
    } catch (e, st) {
      ErrorReporter.reportError(e, st,
          context: 'FacilityCreatorAccountService._fulfillPendingInvites',
          metadata: {'uid': user.uid});
      return false;
    }
  }

  /// [user]'s ties to facilities. Owners can have role rows too (an owner row
  /// per facility), hence the owned read; an invited signup has no role until
  /// their invite is accepted, hence the invite read. Only for a verified
  /// email: the rules refuse the invite query otherwise, which would fail
  /// every ensure for that user, and an unverified address proves nothing
  /// about whose invite it is.
  static Future<AccountTies> _readTies(User user) async {
    final emailLower = user.emailVerified ? _emailLowerOf(user) : null;
    if (emailLower != null) await refreshStaleEmailVerifiedClaim(user);
    final results = await Future.wait([
      _collection(PermissionService.userRolesCollection)
          .where('userId', isEqualTo: user.uid)
          .where('isActive', isEqualTo: true)
          .limit(1)
          .get(),
      _collection('facilities')
          .where('ownerUid', isEqualTo: user.uid)
          .limit(1)
          .get(),
      if (emailLower != null)
        _collectionGroup('invites')
            .where('emailLower', isEqualTo: emailLower)
            .where('status', isEqualTo: 'pending')
            .limit(1)
            .get(),
    ]);
    return AccountTies(
      activeRole: results[0].docs.isNotEmpty,
      ownsFacility: results[1].docs.isNotEmpty,
      pendingInvite: results.length > 2 && results[2].docs.isNotEmpty,
    );
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

