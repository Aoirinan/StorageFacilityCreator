import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:sfcapp/models/facility_creator_account_model.dart';
import 'package:sfcapp/models/facility_model.dart';
import 'package:sfcapp/services/facility_creator_account_service.dart';
import 'package:sfcapp/services/facility_service.dart';
import 'package:sfcapp/services/superadmin_service.dart';
import 'package:sfcapp/services/error_reporter.dart';
import 'package:sfcapp/services/debug_logger.dart';

/// Result of subscription access check
class SubscriptionAccessResult {
  final bool canAccess;
  final String? redirectRoute;
  final String? message;
  final SubscriptionStatus? subscriptionStatus;

  /// False when the check could not read what it needed (the account or the
  /// facilities), so the answer is a fail-closed guess rather than the
  /// account's standing. Never cache it, and don't yank a working session to
  /// /subscription over it from a background re-check.
  final bool verified;

  const SubscriptionAccessResult({
    required this.canAccess,
    this.redirectRoute,
    this.message,
    this.subscriptionStatus,
    this.verified = true,
  });
}

/// The route guard's last access result, for one uid.
///
/// Used to be a single unkeyed global, so a second account signing in on the
/// same tab was let through (or locked out) on the first account's result for
/// up to 2 minutes.
class SubscriptionAccessCache {
  SubscriptionAccessCache({this.ttl = const Duration(minutes: 2)});

  final Duration ttl;
  String? _uid;
  SubscriptionAccessResult? _result;
  DateTime? _fetchedAt;

  /// The stored result if it belongs to [uid] and is younger than [ttl].
  SubscriptionAccessResult? freshFor(String uid, {DateTime? now}) {
    final fetchedAt = _fetchedAt;
    if (_uid != uid || _result == null || fetchedAt == null) return null;
    if ((now ?? DateTime.now()).difference(fetchedAt) >= ttl) return null;
    return _result;
  }

  void store(String uid, SubscriptionAccessResult result, {DateTime? now}) {
    _uid = uid;
    _result = result;
    _fetchedAt = now ?? DateTime.now();
  }

  void clear() {
    _uid = null;
    _result = null;
    _fetchedAt = null;
  }
}

/// Service for checking subscription status and access permissions
/// Used by route guards to restrict access based on subscription status
class SubscriptionGuardService {
  /// Cache the route guard reads before calling [checkAccess].
  static final SubscriptionAccessCache routeGuardCache = SubscriptionAccessCache();

  // The reads checkAccess and shellLock make unless a test passes its own.
  // Both throw on a failed read: the non-throwing account read turns a
  // failure into null ("no account yet, allow"), and the non-throwing
  // facilities read into [] (which looks exactly like a per-facility-billed
  // owner whose subscription lapsed).
  static Future<FacilityCreatorAccountModel?> _readAccount(String uid) =>
      FacilityCreatorAccountService.getAccountByOwnerUidOrThrow(uid);

  static Future<List<FacilityModel>> _readFacilities() =>
      FacilityService.getUserFacilities(
        includeArchived: false,
        forceRefresh: false,
        throwOnError: true,
      );

  /// Check if current user can access a route
  /// Returns access result with redirect route if access is denied
  static Future<SubscriptionAccessResult> checkAccess({
    String? currentRoute,
    bool allowSubscriptionRoutes = true,
    User? userOverride,
    Future<FacilityCreatorAccountModel?> Function(String uid)? accountProvider,
    Future<List<FacilityModel>> Function()? facilitiesProvider,
    Future<bool> Function(String uid, List<FacilityModel> facilities)? activeSubscriptionChecker,
    bool Function()? superAdminResolver,
    FirebaseAuth? authOverride,
  }) async {
    try {
      final auth = authOverride ?? FirebaseAuth.instance;
      final user = userOverride ?? auth.currentUser;
      if (user == null) {
        // Not authenticated - let auth guard handle this
        return const SubscriptionAccessResult(canAccess: true);
      }

      // Superadmins bypass all subscription checks
      final isSuperAdmin = superAdminResolver?.call() ?? SuperAdminService.isSuperAdmin();
      if (isSuperAdmin) {
        if (kDebugMode) {
          print('✅ [SubscriptionGuard] Superadmin - bypassing subscription check');
        }
        // #region agent log
        DebugLogger.log(
          hypothesisId: 'H2',
          location: 'subscription_guard_service.dart:checkAccess',
          message: 'Bypass superadmin',
          data: {'route': currentRoute},
        );
        // #endregion
        return const SubscriptionAccessResult(canAccess: true);
      }

      final account = await (accountProvider ?? _readAccount)(user.uid);
      if (account == null) {
        if (kDebugMode) {
          print('⚠️ [SubscriptionGuard] No account of their own - deciding from their facilities');
        }
        // #region agent log
        DebugLogger.log(
          hypothesisId: 'H2',
          location: 'subscription_guard_service.dart:checkAccess',
          message: 'No account found, deciding from facilities',
          data: {'route': currentRoute, 'user': user.uid},
        );
        // #endregion
      }

      final result = await decideAccess(
        account,
        currentRoute: currentRoute,
        allowSubscriptionRoutes: allowSubscriptionRoutes,
        facilities: facilitiesProvider ?? _readFacilities,
        activeSubscriptionChecker: activeSubscriptionChecker == null
            ? null
            : (facilities) => activeSubscriptionChecker(user.uid, facilities),
      );

      final status = account?.subscriptionStatus;
      if (!result.canAccess) {
        if (kDebugMode) {
          print('❌ [SubscriptionGuard] Access denied - subscription status: ${status?.name}');
        }
        ErrorReporter.reportInfo(
          'SubscriptionGuard deny: status=${status?.name}, route=$currentRoute, user=${user.uid}',
        );
        // #region agent log
        DebugLogger.log(
          hypothesisId: 'H2',
          location: 'subscription_guard_service.dart:checkAccess',
          message: 'Access denied',
          data: {
            'route': currentRoute,
            'status': status?.name,
            'user': user.uid,
            'redirect': result.redirectRoute,
          },
        );
        // #endregion
      } else if (account != null) {
        if (kDebugMode) {
          print('✅ [SubscriptionGuard] Access granted - subscription status: ${status?.name}');
        }
      }
      return result;
    } catch (e) {
      if (kDebugMode) {
        print('❌ [SubscriptionGuard] Error checking access: $e');
      }
      // #region agent log
      DebugLogger.log(
        hypothesisId: 'H2',
        location: 'subscription_guard_service.dart:checkAccess',
        message: 'Error during access check',
        data: {'route': currentRoute, 'error': e.toString()},
      );
      // #endregion
      ErrorReporter.reportError(e, StackTrace.current, context: 'SubscriptionGuard.checkAccess');
      // On error, deny access and route to subscription/help to avoid bypassing guards
      return const SubscriptionAccessResult(
        canAccess: false,
        redirectRoute: '/subscription',
        message: 'We could not verify your subscription status. Please check your connection or try again.',
        verified: false,
      );
    }
  }

  /// [checkAccess]'s rule for an account already read, without its logging.
  ///
  /// [facilities] is read only when the account alone does not decide (and
  /// always for a user with no account), and a failed read reaches the
  /// caller. The route guard (through checkAccess) and the shell's sidebar
  /// lock and lock overlay (through [shellLock]) share it. The lock widgets
  /// had their own copy, which locked out everyone with no account (invited
  /// staff) and cancelled accounts still inside their paid period, both of
  /// which the guard lets in.
  static Future<SubscriptionAccessResult> decideAccess(
    FacilityCreatorAccountModel? account, {
    required Future<List<FacilityModel>> Function() facilities,
    String? currentRoute,
    bool allowSubscriptionRoutes = true,
    Future<bool> Function(List<FacilityModel> facilities)? activeSubscriptionChecker,
  }) async {
    // No account of their own: invited staff (who work in the owner's), a
    // new signup, or an owner whose account was never created.
    if (account == null) {
      return accessWithoutAccount(await facilities());
    }

    // Accounts the platform does not bill are never locked out. Set by a
    // super admin; an owner cannot grant it to themselves.
    if (account.billingExempt) {
      return const SubscriptionAccessResult(canAccess: true);
    }

    // Check subscription status
    final status = account.subscriptionStatus;

    // Always allow access to subscription management routes
    final subscriptionRoutes = [
      '/subscription',
      '/subscription/',
      '/subscription/success',
      '/subscription/cancel',
      '/subscription/manage',
    ];

    if (allowSubscriptionRoutes &&
        currentRoute != null &&
        subscriptionRoutes.any((route) => currentRoute.startsWith(route))) {
      return const SubscriptionAccessResult(canAccess: true);
    }

    // Check if user can access platform (account-level OR per-facility subs)
    final bool hasAccess;
    if (activeSubscriptionChecker != null) {
      hasAccess = await activeSubscriptionChecker(await facilities());
    } else if (account.canAccessPlatform) {
      // Account-level access never depended on the facilities, so don't
      // fetch them just to ignore them.
      hasAccess = true;
    } else {
      // The rule hasActiveSubscription applies, run against the account
      // already read. hasActiveSubscription fetched the account a second
      // time on every guarded navigation.
      hasAccess = FacilityCreatorAccountService.accountGrantsPlatformAccess(
        account,
        facilities: await facilities(),
      );
    }
    if (!hasAccess) {
      String message;
      String redirectRoute = '/subscription';

      if (account.suspended) {
        // Before the cancelled branch below: suspending also cancels the
        // account, and that branch let a cancelled account with a paid period
        // still running straight back in.
        message = 'This account is suspended. Contact support to restore access.';
      } else if (status == SubscriptionStatus.pendingApproval) {
        message = 'Your account is pending approval.';
        redirectRoute = '/pending-approval';
      } else if (status == SubscriptionStatus.pastDue) {
        // Checked before the trial case: an operator who trialled, subscribed,
        // then missed a payment still has a trial end date in the past, and
        // the billing problem is the more useful thing to tell them about.
        message = 'Your subscription payment is past due. Please renew your subscription to continue using the platform.';
        redirectRoute = '/subscription?pastDue=1';
      } else if (account.trialHasEnded &&
          (account.hasTrial || status == SubscriptionStatus.cancelled)) {
        // trialHasEnded rather than isTrialExpired: the nightly sweep moves a
        // lapsed trial to `cancelled`, and this must still name the trial as
        // the reason instead of claiming a subscription was cancelled.
        message = 'Your trial has expired. Please subscribe to continue using the platform.';
        redirectRoute = '/subscription?trialExpired=1';
      } else if (status == SubscriptionStatus.cancelled) {
        if (_insideCancelledPaidPeriod(account)) {
          message = 'Your subscription has been cancelled but you have access until ${account.subscriptionCurrentPeriodEnd!.toString().split(' ')[0]}.';
          // Allow access until period end
          return SubscriptionAccessResult(
            canAccess: true,
            message: message,
            subscriptionStatus: status,
          );
        } else {
          message = 'Your subscription has been cancelled. Please reactivate to continue using the platform.';
        }
      } else if (status == SubscriptionStatus.unpaid) {
        message = 'Please choose a subscription plan to continue using the platform.';
        redirectRoute = '/subscription?requireChoice=true';
      } else {
        message = 'Your subscription status needs attention. Please update your subscription to continue.';
      }

      return SubscriptionAccessResult(
        canAccess: false,
        redirectRoute: redirectRoute,
        message: message,
        subscriptionStatus: status,
      );
    }

    // Return warning message if past due (but still allowing access during grace period)
    if (status == SubscriptionStatus.pastDue) {
      return SubscriptionAccessResult(
        canAccess: true,
        message: 'Your subscription payment is past due. Please renew your subscription soon.',
        subscriptionStatus: status,
      );
    }

    return SubscriptionAccessResult(
      canAccess: true,
      subscriptionStatus: status,
    );
  }

  /// A cancelled account keeps access until the period it paid for ends.
  /// Callers rule out a suspended account first: only an exempt account
  /// overrides a suspension.
  static bool _insideCancelledPaidPeriod(FacilityCreatorAccountModel account) {
    final periodEnd = account.subscriptionCurrentPeriodEnd;
    return account.subscriptionStatus == SubscriptionStatus.cancelled &&
        periodEnd != null &&
        DateTime.now().isBefore(periodEnd);
  }

  /// [decideAccess] for a user with no account of their own, from the
  /// facilities they can see ([FacilityModel.currentUserOwnsFacility] tells
  /// their own from the ones they reach through a role).
  ///
  /// An invited team member is let in only through a facility whose billing
  /// is in good standing ([facilityCoversTeamMember]); staff of a lapsed or
  /// suspended owner lose access like the owner does. They used to be let in
  /// whatever the owner's standing, so a login the owner had invited kept
  /// every facility after the owner's trial lapsed or the account was
  /// suspended. A new signup (no facilities yet) and an owner whose account
  /// was never created are let in as before.
  static SubscriptionAccessResult accessWithoutAccount(List<FacilityModel> facilities) {
    final ownsAny = facilities.any((f) => f.currentUserOwnsFacility != false);
    final team = facilities.where((f) => f.currentUserOwnsFacility == false).toList();
    if (ownsAny || team.isEmpty || team.any(facilityCoversTeamMember)) {
      return const SubscriptionAccessResult(canAccess: true);
    }
    return const SubscriptionAccessResult(
      canAccess: false,
      redirectRoute: '/subscription',
      message: "The facility owner's subscription is not active, so team access "
          'is paused. Ask the owner to renew it.',
    );
  }

  /// Whether the owner's billing for [facility] covers the team members who
  /// work there: an active or trialing subscription on the facility, a
  /// billing-exempt facility, or the owner's own account access, read from
  /// the copy the backend keeps on the facility
  /// ([FacilityModel.ownerAccountStanding]). A suspended owner covers no one
  /// unless their account is exempt, the same as for the owner.
  ///
  /// No copy means the backend knows of no account for the owner, and an
  /// owner with none is let in, so their staff are too.
  static bool facilityCoversTeamMember(FacilityModel facility) {
    final standing = facility.ownerAccountStanding;
    if (standing == null) return true;
    final owner = standing.toAccount(ownerUid: facility.ownerUid);
    if (owner.billingExempt) return true;
    if (owner.suspended) return false;
    if (facility.billingExempt || facility.hasActivePlatformSubscription) return true;
    return owner.canAccessPlatform || _insideCancelledPaidPeriod(owner);
  }

  /// Where the shell's 1-minute background re-check sends the user for
  /// [result], or null to leave them where they are.
  ///
  /// An unverified result means a read failed, not that access lapsed; the
  /// next navigation re-checks. Pulling a working page to /subscription over
  /// a brief read failure is what this avoids.
  static String? backgroundRecheckRedirect(SubscriptionAccessResult result) {
    if (result.canAccess || !result.verified) return null;
    return result.redirectRoute;
  }

  /// Whether the shell's sidebar lock and lock overlay lock for [result].
  ///
  /// Null when it is unverified (a read failed): keep showing what is shown,
  /// and let the route guard fail closed on the next navigation. Pending
  /// approval has its own page and guard, so the shell does not lock it.
  static bool? shellLockFor(SubscriptionAccessResult result) {
    if (!result.verified) return null;
    if (result.canAccess) return false;
    return result.redirectRoute != '/pending-approval';
  }

  /// The sidebar lock and lock overlay's answer for [uid]: [decideAccess] on
  /// the account, the rule the route guard applies, without the guard's
  /// logging (the overlay asks every 10 s). `locked` is null when a read
  /// failed. No route is passed, so subscription pages get no exemption: the
  /// sidebar stays locked on them. `message` says why (the lock overlay shows
  /// it ahead of the account's status: a suspended account's reads
  /// "cancelled").
  static Future<({FacilityCreatorAccountModel? account, bool? locked, String? message})>
      shellLock(
    String uid, {
    Future<FacilityCreatorAccountModel?> Function(String uid)? accountProvider,
    Future<List<FacilityModel>> Function()? facilitiesProvider,
  }) async {
    try {
      final account = await (accountProvider ?? _readAccount)(uid);
      final result = await decideAccess(
        account,
        facilities: facilitiesProvider ?? _readFacilities,
      );
      return (account: account, locked: shellLockFor(result), message: result.message);
    } catch (e) {
      debugPrint('⚠️ [SubscriptionGuard] Shell lock check failed: $e');
      return (account: null, locked: null, message: null);
    }
  }

  /// Check if user needs to see subscription warning banner
  static Future<bool> shouldShowWarning() async {
    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user == null || SuperAdminService.isSuperAdmin()) {
        return false;
      }

      final account = await FacilityCreatorAccountService.getAccountByOwnerUid(user.uid);
      if (account == null) {
        return false;
      }

      // Pending approval accounts see a dedicated screen, not a warning banner
      if (account.isPendingApproval) return false;

      // Show warning if trial expired, past due, or cancelled (but still have access)
      return (account.hasTrial && account.isTrialExpired) ||
             account.subscriptionStatus == SubscriptionStatus.pastDue ||
             (account.subscriptionStatus == SubscriptionStatus.cancelled &&
              account.subscriptionCurrentPeriodEnd != null &&
              DateTime.now().isBefore(account.subscriptionCurrentPeriodEnd!));
    } catch (e) {
      return false;
    }
  }

  /// Get warning message for current subscription status
  static Future<String?> getWarningMessage() async {
    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user == null || SuperAdminService.isSuperAdmin()) {
        return null;
      }

      final account = await FacilityCreatorAccountService.getAccountByOwnerUid(user.uid);
      if (account == null) {
        return null;
      }

      if (account.hasTrial && account.isTrialExpired) {
        return 'Your trial has expired. Please subscribe to continue using the app.';
      }

      if (account.subscriptionStatus == SubscriptionStatus.pastDue) {
        return 'Your subscription payment is past due. Please renew your subscription to continue.';
      }

      if (account.subscriptionStatus == SubscriptionStatus.cancelled &&
          account.subscriptionCurrentPeriodEnd != null &&
          DateTime.now().isBefore(account.subscriptionCurrentPeriodEnd!)) {
        final endDate = account.subscriptionCurrentPeriodEnd!.toString().split(' ')[0];
        return 'Your subscription has been cancelled. You have access until $endDate.';
      }

      return null;
    } catch (e) {
      return null;
    }
  }

  /// Get account for current user (helper for banner)
  static Future<FacilityCreatorAccountModel?> getCurrentAccount() async {
    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) return null;
      return await FacilityCreatorAccountService.getAccountByOwnerUid(user.uid);
    } catch (e) {
      return null;
    }
  }
}

