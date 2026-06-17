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
import '../config/web_host_config.dart';
import '../utils/browser_location_stub.dart'
    if (dart.library.html) '../utils/browser_location_web.dart' as browser_location;
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
  User? effectiveUser = firebaseUser;

  final loc = state.matchedLocation;
  final path = state.uri.path;

  // Legacy tenant move-in links used /move-in?token=...; redirect to the public flow.
  if (loc == AppRoute.moveInWizard || path == AppRoute.moveInWizard) {
    final token = state.uri.queryParameters['token'];
    final facilityId = state.uri.queryParameters['facilityId'] ?? '';
    if (token != null && token.isNotEmpty && facilityId.isEmpty) {
      return Uri(
        path: AppRoute.publicMoveIn,
        queryParameters: state.uri.queryParameters,
      ).toString();
    }
  }

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

  // app.* hosts the signed-in product; marketing is on storagefacilitycreator.com (Vercel).
  if (isProductionAppWebHost()) {
    const marketingMirrorPaths = {
      '/privacy',
      '/terms',
      '/sms-policy',
      '/contact',
    };
    if (marketingMirrorPaths.contains(path)) {
      browser_location.assignWindowLocation('$kMarketingWebsiteOrigin$path');
      return null;
    }
    final onMarketingPath =
        path == AppRoute.marketing || loc == AppRoute.marketing;
    if (!isAuthenticated && (isLanding || onMarketingPath)) {
      return AppRoute.login;
    }
  }

  // Define public routes that don't require authentication
  final publicRoutes = {
    AppRoute.landing,
    AppRoute.marketing,
    '/privacy',
    '/terms',
    '/sms-policy',
    '/contact',
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
      path == '/privacy' ||
      path == '/terms' ||
      path == '/sms-policy' ||
      path == '/contact' ||
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
    if (isPublicRoute) return null;
    final intended = state.uri.toString();
    final encodedIntended = Uri.encodeComponent(intended);
    return '${AppRoute.login}?redirect=$encodedIntended';
  }

  // Enforce email verification before allowing access to authenticated app routes.
  // Keep users on login/signup/verify while they complete verification.
  final isVerificationAllowedRoute = loggingIn ||
      loc == AppRoute.signup ||
      loc == AppRoute.verifyEmail ||
      loc == AppRoute.forgotPassword;
  if (!SuperAdminService.isSuperAdmin(firebaseUser)) {
    final verifiedUser = firebaseUser;
    if (verifiedUser == null) {
      return AppRoute.login;
    }
    try {
      await verifiedUser.reload();
      effectiveUser = FirebaseAuth.instance.currentUser;
    } catch (_) {
      // If refresh fails, fall back to the current auth snapshot.
      effectiveUser = verifiedUser;
    }

    if (effectiveUser != null &&
        !effectiveUser.emailVerified &&
        !isVerificationAllowedRoute) {
      final email = Uri.encodeComponent(effectiveUser.email ?? '');
      return '${AppRoute.verifyEmail}?email=$email';
    }
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
  // Keep authenticated users on public commerce routes (rental/payment/move-in/map pages)
  // so facility owners can test the public flow while signed in.
  final isPublicCommerceRoute = path.startsWith(AppRoute.publicPayment) ||
      path.startsWith(AppRoute.publicRental) ||
      path.startsWith('${AppRoute.publicFacility}/') ||
      path.startsWith('${AppRoute.publicMapBase}/') ||
      path.startsWith('${AppRoute.publicFacilityRentalBase}/');
  if (isAuthenticated &&
      publicRoutes.contains(loc) &&
      loc != AppRoute.acceptInvite &&
      loc != AppRoute.contractSign &&
      loc != AppRoute.legacyScreen &&
      loc != AppRoute.publicMoveIn &&
      !isPublicCommerceRoute &&
      !loggingIn) {
    // Allow users to stay on signup/verify-email routes if email is not verified
    final isSignupOrVerifyEmail =
        loc == AppRoute.signup || loc == AppRoute.verifyEmail;
    if (isSignupOrVerifyEmail &&
        effectiveUser != null &&
        !effectiveUser.emailVerified) {
      // #region agent log
      debugSessionLog(
          hypothesisId: 'H3',
          location: 'route_guards.dart:routeGuard',
          message: 'Allow unverified user on signup/verify-email',
          data: {'loc': loc, 'emailVerified': effectiveUser.emailVerified});
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

  // Maintenance mode: keep users without platform access on subscription; allow trial/active
  // (Previously this blocked everyone except super admins, which trapped trial accounts on /subscription.)
  if (isAuthenticated &&
      !isPublicRoute &&
      !path.startsWith('/subscription') &&
      !path.startsWith(AppRoute.superAdmin) &&
      !SuperAdminService.isSuperAdmin(firebaseUser)) {
    final isMaintenanceMode = ref.read(maintenanceModeProvider);
    if (isMaintenanceMode && !path.startsWith('/maintenance')) {
      try {
        final maintenanceGate = await SubscriptionGuardService.checkAccess(
          currentRoute: path,
          allowSubscriptionRoutes: true,
        );
        if (!maintenanceGate.canAccess) {
          return '/subscription?maintenance=1';
        }
      } catch (e) {
        if (kDebugMode) {
          print('⚠️ Maintenance mode subscription check failed: $e');
        }
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
        // Don't cache trialing/pending results: status can change quickly.
        final status = subscriptionCheck.subscriptionStatus;
        final shouldBypassCache = status == SubscriptionStatus.trialing ||
            status == SubscriptionStatus.pendingApproval;
        if (!shouldBypassCache) {
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
