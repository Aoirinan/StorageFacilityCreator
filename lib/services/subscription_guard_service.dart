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

      // Get account for current user. The throwing read: the other one turns
      // a failed read into null, which reads as "no account yet, allow".
      final accountFetcher = accountProvider ??
          FacilityCreatorAccountService.getAccountByOwnerUidOrThrow;
      final account = await accountFetcher(user.uid);

      // Accounts the platform does not bill are never locked out. Set by a
      // super admin; an owner cannot grant it to themselves.
      if (account != null && account.billingExempt) {
        return const SubscriptionAccessResult(canAccess: true);
      }
      if (account == null) {
        // No account yet - allow access (will be created on first facility creation)
        if (kDebugMode) {
          print('⚠️ [SubscriptionGuard] No account found - allowing access');
        }
        // #region agent log
        DebugLogger.log(
          hypothesisId: 'H2',
          location: 'subscription_guard_service.dart:checkAccess',
          message: 'No account found, allowing',
          data: {'route': currentRoute, 'user': user.uid},
        );
        // #endregion
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
      // Throwing, for the same reason: a failed read returned [], which looks
      // exactly like a per-facility-billed owner whose subscription lapsed.
      final facilitiesFetcher = facilitiesProvider ??
          () => FacilityService.getUserFacilities(
                includeArchived: false,
                forceRefresh: false,
                throwOnError: true,
              );
      final bool hasAccess;
      if (activeSubscriptionChecker != null) {
        hasAccess = await activeSubscriptionChecker(user.uid, await facilitiesFetcher());
      } else if (account.canAccessPlatform) {
        // Account-level access never depended on the facilities, so don't
        // fetch them just to ignore them.
        hasAccess = true;
      } else {
        // The rule hasActiveSubscription applies, run against the account
        // fetched above. hasActiveSubscription fetched the account a second
        // time on every guarded navigation.
        hasAccess = FacilityCreatorAccountService.accountGrantsPlatformAccess(
          account,
          facilities: await facilitiesFetcher(),
        );
      }
      if (!hasAccess) {
        if (kDebugMode) {
          print('❌ [SubscriptionGuard] Access denied - subscription status: ${status.name}');
        }
        ErrorReporter.reportInfo(
          'SubscriptionGuard deny: status=${status.name}, route=$currentRoute, user=${user.uid}',
        );
        String message;
        String redirectRoute = '/subscription';

        // #region agent log
        DebugLogger.log(
          hypothesisId: 'H2',
          location: 'subscription_guard_service.dart:checkAccess',
          message: 'Access denied',
          data: {
            'route': currentRoute,
            'status': status.name,
            'user': user.uid,
            'redirect': redirectRoute,
          },
        );
        // #endregion

        if (status == SubscriptionStatus.pendingApproval) {
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
          if (account.subscriptionCurrentPeriodEnd != null &&
              DateTime.now().isBefore(account.subscriptionCurrentPeriodEnd!)) {
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

      // Access granted
      if (kDebugMode) {
        print('✅ [SubscriptionGuard] Access granted - subscription status: ${status.name}');
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

