import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../models/facility_creator_account_model.dart';
import '../providers/feature_flag_provider.dart';
import '../providers/two_factor_provider.dart';
import '../services/debug_session_logger.dart';
import '../services/subscription_guard_service.dart';
import '../services/superadmin_service.dart';
import '../services/two_factor_service.dart';
import 'app_route.dart';

/// Cache for subscription check results to avoid repeated calls
class _SubscriptionCheckCache {
  SubscriptionAccessResult? result;
  DateTime? fetchedAt;

  bool get isFresh =>
      result != null &&
      fetchedAt != null &&
      DateTime.now().difference(fetchedAt!) < const Duration(minutes: 2);
}

final _subscriptionCheckCache = _SubscriptionCheckCache();

/// Main redirect guard function for GoRouter
///
/// Handles:
/// - Authentication checks
/// - Public route access
/// - Subscription status checks
/// - Redirects to appropriate pages
Future<String?> routeGuard(
  BuildContext context,
  GoRouterState state,
  Ref ref,
) async {
  // Use Firebase currentUser directly so we stay in sync with refreshListenable.
  // Riverpod's auth stream can lag; redirect was seeing "loading"/null right after
  // sign-in and leaving user on landing until refresh.
  final firebaseUser = FirebaseAuth.instance.currentUser;
  final isAuthenticated = firebaseUser != null;

  final loc = state.matchedLocation;
  final path = state.uri.path;
  // Legacy redirects: Autopay Activity and Notifications removed from sidebar; single source in Payments > Autopay and Settings > Notifications
  if (path == AppRoute.autopayActivity ||
      path.startsWith('${AppRoute.autopayActivity}?')) {
    return '${AppRoute.payments}?tab=autopay';
  }
  if (path == AppRoute.facilityNotifications ||
      path.startsWith('${AppRoute.facilityNotifications}?')) {
    return AppRoute.notificationSettings;
  }
  final isLanding = path == '/' || loc == AppRoute.landing || loc.isEmpty;
  final loggingIn = loc == AppRoute.login ||
      path == AppRoute.login ||
      path.startsWith('${AppRoute.login}?') ||
      path.startsWith('${AppRoute.login}/');

  // Define public routes that don't require authentication
  final publicRoutes = {
    AppRoute.landing,
    AppRoute.marketing,
    AppRoute.login,
    AppRoute.signup,
    AppRoute.forgotPassword,
    AppRoute.verifyEmail,
    AppRoute.tenantPortal,
    AppRoute.contractSign,
    AppRoute.acceptInvite,
    AppRoute.publicPayment,
    AppRoute.publicRental,
    AppRoute.publicMoveIn,
    AppRoute.publicFacility,
    AppRoute.publicMapBase,
    AppRoute.publicFacilityRentalBase,
    AppRoute.legacyScreen,
    AppRoute.pendingApproval,
  };

  // Check if current path matches any public route (including with query params)
  final isPublicRoute = publicRoutes.contains(loc) ||
      path == AppRoute.acceptInvite ||
      path.startsWith(AppRoute.acceptInvite + '/') ||
      path.startsWith(AppRoute.acceptInvite + '?') ||
      path.startsWith('${AppRoute.publicFacility}/') ||
      path.startsWith('${AppRoute.publicMapBase}/') ||
      path.startsWith('${AppRoute.publicFacilityRentalBase}/') ||
      path.startsWith(AppRoute.publicPayment) ||
      path.startsWith(AppRoute.publicRental);

  // Handle unauthenticated users
  if (!isAuthenticated) {
    // #region agent log
    debugSessionLog(
        hypothesisId: 'H3',
        location: 'route_guards.dart:routeGuard',
        message: 'Unauthenticated',
        data: {
          'loc': loc,
          'isLanding': isLanding,
          'isPublicRoute': isPublicRoute
        });
    // #endregion
    // Reset 2FA verification state when logged out
    ref.read(twoFactorVerifiedProvider.notifier).state = false;
    // Always allow the root/login entry point for signed-out users
    if (isLanding) return null;
    return isPublicRoute ? null : AppRoute.login;
  }

  // Check 2FA requirement for authenticated users (including when on /login)
  // We must not redirect from /login to dashboard until 2FA is verified when 2FA is enabled.
  if (isAuthenticated) {
    final is2FAVerified = ref.read(twoFactorVerifiedProvider);

    if (!is2FAVerified) {
      try {
        final is2FAEnabled = await TwoFactorService.is2FAEnabled();

        if (is2FAEnabled) {
          if (loggingIn) {
            // Stay on login so the OTP dialog can be shown; do not redirect to dashboard.
            // #region agent log
            debugSessionLog(
                hypothesisId: 'H3',
                location: 'route_guards.dart:routeGuard',
                message: '2FA enabled on login, stay for OTP',
                data: {'loc': loc});
            // #endregion
            return null;
          }
          // 2FA enabled but not on login - redirect to login to complete 2FA
          // #region agent log
          debugSessionLog(
              hypothesisId: 'H3',
              location: 'route_guards.dart:routeGuard',
              message: '2FA enabled, redirect to login',
              data: {'loc': loc});
          // #endregion
          if (kDebugMode) {
            print(
                '🔐 2FA is enabled but not verified - redirecting to login for 2FA verification');
          }
          return AppRoute.login;
        } else {
          // #region agent log
          debugSessionLog(
              hypothesisId: 'H3',
              location: 'route_guards.dart:routeGuard',
              message: '2FA not enabled, mark verified, return null',
              data: {'loc': loc});
          // #endregion
          ref.read(twoFactorVerifiedProvider.notifier).state = true;
          ref.invalidate(twoFactorEnabledProvider);
          return null;
        }
      } catch (e) {
        if (kDebugMode) {
          print('⚠️ Error checking 2FA status: $e');
        }
        ref.read(twoFactorVerifiedProvider.notifier).state = true;
        return null;
      }
    }
  }

  // Never redirect from /login to dashboard when 2FA is not verified.
  // Safety net: even if 2FA block fell through or login detection failed above.
  if (isAuthenticated && loggingIn && !ref.read(twoFactorVerifiedProvider)) {
    // #region agent log
    debugSessionLog(
        hypothesisId: 'H3',
        location: 'route_guards.dart:routeGuard',
        message: 'Block login->dashboard, stay for 2FA',
        data: {'loc': loc, 'path': path});
    // #endregion
    return null;
  }

  // Helper: never redirect to dashboard when 2FA is enabled but not verified.
  // Call before every "return AppRoute.dashboard" so we never bypass 2FA.
  Future<String> redirectToDashboardOrLoginIf2FA() async {
    if (!ref.read(twoFactorVerifiedProvider)) {
      try {
        final en = await TwoFactorService.is2FAEnabled();
        if (en) return AppRoute.login;
      } catch (_) {
        return AppRoute.login;
      }
    }
    return AppRoute.dashboard;
  }

  // Redirect authenticated users from landing page to dashboard
  if (isAuthenticated && (loc == AppRoute.landing || path == '/')) {
    final target = await redirectToDashboardOrLoginIf2FA();
    // #region agent log
    debugSessionLog(
        hypothesisId: 'H3',
        location: 'route_guards.dart:routeGuard',
        message: target == AppRoute.dashboard
            ? 'Redirect landing->dashboard'
            : 'Redirect landing->login (2FA)',
        data: {'loc': loc});
    // #endregion
    return target;
  }

  // Redirect authenticated users from other public routes (e.g. signup, forgot-password) to dashboard.
  // Never redirect from /login: only the login screen may navigate to dashboard after 2FA is complete.
  // Also allow users to stay on signup/verify-email routes if their email is not verified yet.
  // Allow contract sign: managers may click "Sign" from contract detail to open the signing flow.
  if (isAuthenticated &&
      publicRoutes.contains(loc) &&
      loc != AppRoute.acceptInvite &&
      loc != AppRoute.contractSign &&
      loc != AppRoute.legacyScreen &&
      !loggingIn) {
    // Allow users to stay on signup/verify-email routes if email is not verified
    final isSignupOrVerifyEmail =
        loc == AppRoute.signup || loc == AppRoute.verifyEmail;
    if (isSignupOrVerifyEmail &&
        firebaseUser != null &&
        !firebaseUser.emailVerified) {
      // #region agent log
      debugSessionLog(
          hypothesisId: 'H3',
          location: 'route_guards.dart:routeGuard',
          message: 'Allow unverified user on signup/verify-email',
          data: {'loc': loc, 'emailVerified': firebaseUser.emailVerified});
      // #endregion
      return null; // Allow them to stay on these routes
    }

    final target = await redirectToDashboardOrLoginIf2FA();
    // #region agent log
    debugSessionLog(
        hypothesisId: 'H3',
        location: 'route_guards.dart:routeGuard',
        message: target == AppRoute.dashboard
            ? 'Redirect public auth->dashboard'
            : 'Redirect public->login (2FA)',
        data: {'loc': loc});
    // #endregion
    return target;
  }

  // Maintenance mode: block all non-superadmin authenticated users from app routes
  if (isAuthenticated &&
      !isPublicRoute &&
      !path.startsWith('/subscription') &&
      !path.startsWith(AppRoute.superAdmin) &&
      !SuperAdminService.isSuperAdmin(firebaseUser)) {
    final isMaintenanceMode = ref.read(maintenanceModeProvider);
    if (isMaintenanceMode) {
      // Allow /maintenance route if it exists; otherwise redirect to subscription page with a message
      if (!path.startsWith('/maintenance')) {
        return '/subscription?maintenance=1';
      }
    }
  }

  // Super admin route guard: only superadmin can access /super-admin
  if (path.startsWith(AppRoute.superAdmin)) {
    if (!isAuthenticated) return AppRoute.login;
    if (!SuperAdminService.isSuperAdmin(firebaseUser)) {
      return AppRoute.dashboard;
    }
    return null; // Allow superadmin through
  }

  // Check subscription status for authenticated users (skip for subscription routes)
  if (isAuthenticated && !isPublicRoute && !path.startsWith('/subscription')) {
    SubscriptionAccessResult? subscriptionCheck;
    final cacheIsFresh = _subscriptionCheckCache.isFresh;

    if (cacheIsFresh) {
      subscriptionCheck = _subscriptionCheckCache.result;
    } else {
      try {
        subscriptionCheck = await SubscriptionGuardService.checkAccess(
          currentRoute: path,
          allowSubscriptionRoutes: true,
        );
        // Don't cache when trialing or pending: status can change at any time
        final isTrialing =
            subscriptionCheck.subscriptionStatus == SubscriptionStatus.trialing;
        final isPending = subscriptionCheck.subscriptionStatus ==
            SubscriptionStatus.pendingApproval;
        if (!(subscriptionCheck.canAccess && (isTrialing || isPending))) {
          _subscriptionCheckCache
            ..result = subscriptionCheck
            ..fetchedAt = DateTime.now();
        }
      } catch (e) {
        // Fail closed to avoid bypassing access control on errors
        if (kDebugMode) {
          print('⚠️ Subscription check error: $e');
        }
        return AppRoute.subscription;
      }
    }

    if (subscriptionCheck != null &&
        !subscriptionCheck.canAccess &&
        subscriptionCheck.redirectRoute != null) {
      if (kDebugMode) {
        print(
            '🚫 Subscription redirect from $path to ${subscriptionCheck.redirectRoute}');
      }
      return subscriptionCheck.redirectRoute;
    }
  }

  // #region agent log
  debugSessionLog(
      hypothesisId: 'H3',
      location: 'route_guards.dart:routeGuard',
      message: 'No redirect, return null',
      data: {'loc': loc, 'path': path});
  // #endregion
  return null;
}
