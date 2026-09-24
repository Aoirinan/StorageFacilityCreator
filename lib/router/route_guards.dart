import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../models/facility_creator_account_model.dart';
import 'package:sfcapp/models/feature_flag_model.dart';
import '../providers/feature_flag_provider.dart';
import '../providers/two_factor_provider.dart';
import '../services/debug_session_logger.dart';
import 'package:sfcapp/services/facility_creator_account_service.dart';
import '../services/subscription_guard_service.dart';
import '../services/superadmin_service.dart';
import '../services/two_factor_service.dart';
import 'package:sfcapp/services/user_session_caches.dart';
import '../config/web_host_config.dart';
import 'package:sfcapp/utils/single_flight.dart';
import '../utils/browser_location_stub.dart'
    if (dart.library.html) '../utils/browser_location_web.dart' as browser_location;
import 'app_route.dart';

/// Upper bound on the Firebase Auth token refresh performed during a redirect.
/// On timeout the guard falls back to the cached auth snapshot, which still
/// routes unverified users to verify-email.
const Duration _authRefreshTimeout = Duration(seconds: 6);

/// Upper bound on the two-factor lookup performed during a redirect. On timeout
/// the guard fails closed and routes to login rather than treating an
/// unreachable backend as "no second factor required".
const Duration _twoFactorLookupTimeout = Duration(seconds: 6);

/// Upper bound on a subscription/access lookup performed during a redirect.
/// On timeout the guard sends the user to /subscription, the same fail-closed
/// destination it already uses when the lookup throws.
const Duration _accessCheckTimeout = Duration(seconds: 8);

/// Upper bound on waiting for the feature flags doc during a redirect, for the
/// maintenance check. On timeout maintenance counts as off (see
/// [maintenanceModeForGuard]).
const Duration _featureFlagsWait = Duration(seconds: 3);

/// Whether maintenance mode is on, for the guard: waits (bounded) for the
/// feature flags doc instead of reading whatever has loaded.
///
/// Until that doc arrives, featureFlagEnabledProvider reads every flag as on,
/// maintenance included. The first navigation after a reload reaches the
/// maintenance check before the doc has loaded, so pending, lapsed and
/// past-due users were sent to /subscription?maintenance=1 and a maintenance
/// notice instead of their own page. When the flags cannot be read at all,
/// maintenance counts as off: its gate applies the same access rule as the
/// subscription check below and only changes which page explains a denial.
@visibleForTesting
Future<bool> maintenanceModeForGuard(Ref ref, {Duration wait = _featureFlagsWait}) async {
  // Listened to, not just read: Riverpod pauses a provider nobody listens to,
  // and on a cold load no widget watches the flags yet, so a plain read of
  // its future would only ever time out.
  ProviderSubscription<Future<List<FeatureFlagModel>>>? flags;
  try {
    flags = ref.listen(featureFlagsProvider.future, (_, __) {});
    await flags.read().timeout(wait);
    return ref.read(maintenanceModeProvider);
  } catch (_) {
    return false;
  } finally {
    flags?.close();
  }
}

/// Shares one in-flight subscription check per uid. On a hard reload the
/// initial redirect and the auth-state refresh run the guard at the same time,
/// and each used to run its own account + facilities lookups.
final _subscriptionCheckFlight = SingleFlight<String, SubscriptionAccessResult>();

/// Whether the guard must refresh [user] from Firebase Auth before checking
/// email verification. Only an unverified account can change here (the link
/// was clicked in another tab); a verified one paid an Auth round trip on
/// every single navigation for nothing.
bool needsVerificationReload(User user) => !user.emailVerified;

/// Throttles the background [User.reload] the guard fires for verified users.
///
/// That reload is what ends, within a minute, a session a super admin
/// disabled or whose password was changed elsewhere (superAdminDisableUser
/// also revokes the refresh tokens, but that alone only stops the next hourly
/// token refresh): Auth answers USER_DISABLED or TOKEN_EXPIRED, the SDK
/// signs the user out, and the router's refreshListenable re-runs this guard,
/// which sends them to /login. Awaiting it on every navigation cost a round
/// trip each click; once a minute, in the background, keeps the check without
/// the wait.
@visibleForTesting
class VerifiedUserRecheck {
  VerifiedUserRecheck({this.interval = const Duration(seconds: 60)});

  final Duration interval;
  String? _uid;
  DateTime? _lastAt;

  /// Whether [uid] is due a re-check at [now]. Records the check when it is,
  /// so only the first navigation in each [interval] fires one. A different
  /// account is always due.
  bool claim(String uid, DateTime now) {
    final lastAt = _lastAt;
    if (_uid == uid && lastAt != null && now.difference(lastAt) < interval) {
      return false;
    }
    _uid = uid;
    _lastAt = now;
    return true;
  }

  void reset() {
    _uid = null;
    _lastAt = null;
  }
}

@visibleForTesting
final VerifiedUserRecheck verifiedUserRecheck = VerifiedUserRecheck();

/// Upper bound on the guard's first-load account ensure. On timeout the
/// navigation carries on, and the next one tries again.
const Duration _ensureAccountTimeout = Duration(seconds: 8);

/// Whether the guard makes sure a signed-in new signup has an owner account
/// before checking their access (see
/// [FacilityCreatorAccountService.ensureAccountOnce] with
/// `createOnlyForNewSignups`, which first accepts any invites addressed to
/// their email and creates nothing for staff, the invited or an owner who
/// already has facilities). Not on public pages, not for super admins, and
/// not before the email is verified: the account's creation sends the owner
/// and the platform the onboarding emails.
bool guardEnsuresOwnerAccount({
  required bool isPublicRoute,
  required bool isSuperAdmin,
  required bool emailVerified,
}) =>
    !isPublicRoute && !isSuperAdmin && emailVerified;

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
) {
  return evaluateRouteGuard(
    matchedLocation: state.matchedLocation,
    uri: state.uri,
    ref: ref,
  );
}

/// [routeGuard] without the GoRouter types, with seams for tests. Production
/// passes none of the optional arguments and gets the real Firebase user,
/// super-admin list, 2FA lookup and subscription check.
@visibleForTesting
Future<String?> evaluateRouteGuard({
  required String matchedLocation,
  required Uri uri,
  required Ref ref,
  User? Function()? currentUser,
  bool Function(User? user)? isSuperAdmin,
  Future<bool> Function()? isTwoFactorEnabled,
  Future<SubscriptionAccessResult> Function(String path)? checkAccess,
  DateTime Function()? clock,
  Future<bool> Function(User user)? ensureOwnerAccount,
}) async {
  final User? Function() readCurrentUser =
      currentUser ?? () => FirebaseAuth.instance.currentUser;
  final bool Function(User? user) superAdmin =
      isSuperAdmin ?? (User? user) => SuperAdminService.isSuperAdmin(user);
  final Future<bool> Function() twoFactorEnabled =
      isTwoFactorEnabled ?? TwoFactorService.is2FAEnabledStrict;
  final Future<SubscriptionAccessResult> Function(String path) accessCheck =
      checkAccess ??
          (String path) => SubscriptionGuardService.checkAccess(
                currentRoute: path,
                allowSubscriptionRoutes: true,
              );

  // Use Firebase currentUser directly so we stay in sync with refreshListenable.
  // Riverpod's auth stream can lag; redirect was seeing "loading"/null right after
  // sign-in and leaving user on landing until refresh.
  final firebaseUser = readCurrentUser();
  final isAuthenticated = firebaseUser != null;
  User? effectiveUser = firebaseUser;

  final loc = matchedLocation;
  final path = uri.path;

  // Legacy tenant move-in links used /move-in?token=...; redirect to the public flow.
  if (loc == AppRoute.moveInWizard || path == AppRoute.moveInWizard) {
    final token = uri.queryParameters['token'];
    final facilityId = uri.queryParameters['facilityId'] ?? '';
    if (token != null && token.isNotEmpty && facilityId.isEmpty) {
      return Uri(
        path: AppRoute.publicMoveIn,
        queryParameters: uri.queryParameters,
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
    // Most sign-out buttons call FirebaseAuth.signOut directly rather than
    // AuthService.signOut, so drop the per-account caches here as well.
    UserSessionCaches.clearAll();
    // Always allow the root/login entry point for signed-out users
    if (isLanding) return null;
    if (isPublicRoute) return null;
    final intended = uri.toString();
    final encodedIntended = Uri.encodeComponent(intended);
    return '${AppRoute.login}?redirect=$encodedIntended';
  }

  // Loads alongside the lookups below rather than after them; only the
  // maintenance check waits for it, and it never throws.
  final maintenanceMode = maintenanceModeForGuard(ref);

  // Enforce email verification before allowing access to authenticated app routes.
  // Keep users on login/signup/verify while they complete verification.
  final isVerificationAllowedRoute = loggingIn ||
      loc == AppRoute.signup ||
      loc == AppRoute.verifyEmail ||
      loc == AppRoute.forgotPassword;
  if (!superAdmin(firebaseUser)) {
    final verifiedUser = firebaseUser;
    if (verifiedUser == null) {
      return AppRoute.login;
    }
    if (needsVerificationReload(verifiedUser)) {
      try {
        // Bounded: without a timeout a slow or stalled network freezes the
        // router mid-redirect, leaving the previous screen painted with no
        // spinner and no error.
        await verifiedUser.reload().timeout(_authRefreshTimeout);
        effectiveUser = readCurrentUser();
      } catch (_) {
        // If refresh fails or times out, fall back to the current auth snapshot.
        // An unverified snapshot still routes to verify-email below, so this
        // degrades closed rather than letting an unverified user through.
        effectiveUser = verifiedUser;
      }
    } else if (verifiedUserRecheck.claim(
        verifiedUser.uid, (clock ?? DateTime.now)())) {
      // Not awaited: this navigation proceeds on the current snapshot. If the
      // account was disabled or its password changed, the SDK signs it out
      // when this settles and the guard runs again (see VerifiedUserRecheck).
      unawaited(verifiedUser.reload().catchError((Object _) {}));
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
        final is2FAEnabled =
            await twoFactorEnabled().timeout(_twoFactorLookupTimeout);

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
              message: '2FA not enabled, mark verified',
              data: {'loc': loc});
          // #endregion
          ref.read(twoFactorVerifiedProvider.notifier).state = true;
          ref.invalidate(twoFactorEnabledProvider);
          // This used to return null for every route, so the first navigation
          // after each reload skipped the maintenance, super-admin and
          // subscription checks below: an expired trial could use whatever
          // page it reloaded. Those checks only ever apply to non-public
          // routes, so public ones still stop here, exactly as before (a fresh
          // load of the tenant portal is not bounced to the dashboard).
          if (isPublicRoute || isLanding) return null;
        }
      } catch (e) {
        // Fail closed. We could not determine whether this account requires a
        // second factor, so do not mark it satisfied: that would let anyone
        // holding just the password through whenever this lookup fails.
        if (kDebugMode) {
          print('⚠️ Error checking 2FA status, failing closed: $e');
        }
        // Already on login: stay put so the screen can retry and show its own
        // error. Redirecting to login from login would be a redirect loop.
        if (loggingIn) return null;
        return AppRoute.login;
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
        final en = await twoFactorEnabled().timeout(_twoFactorLookupTimeout);
        if (en) return AppRoute.login;
      } catch (_) {
        // Fail closed: an undetermined second factor must not land on dashboard.
        return AppRoute.login;
      }
    }
    return AppRoute.dashboard;
  }

  // One access answer per uid, shared by the pending-approval exception and
  // the subscription check below, so they cost one lookup between them.
  //
  // Keyed by uid alone although [accessCheck] takes the path: checkAccess only
  // reads the path to let /subscription routes through, and neither caller
  // runs for those. Anything that does must not use this cache, or it would
  // hand every later route the "subscription pages are allowed" answer.
  Future<SubscriptionAccessResult> sharedAccessCheck(String uid) async {
    assert(!path.startsWith('/subscription'),
        'the uid-keyed access cache must not hold a /subscription answer');
    final cached = SubscriptionGuardService.routeGuardCache.freshFor(uid);
    if (cached != null) return cached;

    final result = await _subscriptionCheckFlight.run(
      uid,
      () => accessCheck(path).timeout(_accessCheckTimeout),
    );
    // Only a confirmed grant is kept. Trialing/pending status can change
    // quickly. A cached denial turned one transient failure (a failed
    // facilities read looks like a lapsed per-facility subscription) into a
    // 2-minute lockout. An unverified answer is a fail-closed guess made when
    // a read failed, not the account's standing.
    final status = result.subscriptionStatus;
    final cacheable = result.canAccess &&
        result.verified &&
        status != SubscriptionStatus.trialing &&
        status != SubscriptionStatus.pendingApproval;
    if (cacheable) {
      SubscriptionGuardService.routeGuardCache.store(uid, result);
    }
    return result;
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

    // /pending-approval is where the subscription check sends a pending
    // account. Bouncing it on to the dashboard here (including every time the
    // shell's 1-minute checker sent it back) left pending users on the
    // dashboard. Everyone else still leaves it, as does a pending user whose
    // check fails.
    if (loc == AppRoute.pendingApproval && !superAdmin(firebaseUser)) {
      try {
        final access = await sharedAccessCheck(firebaseUser.uid);
        if (!access.canAccess &&
            access.redirectRoute == AppRoute.pendingApproval) {
          return null;
        }
      } catch (_) {
        // Fall through to the dashboard, as before.
      }
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

  // First authenticated load: a new signup gets their pendingApproval account
  // here, before the access check reads it, rather than only once they open a
  // screen that creates one (so their onboarding emails went out late, and
  // they saw an unlocked, empty dashboard). An invited signup's invites are
  // accepted here first, so they arrive as staff instead of being given an
  // account that held them on /pending-approval. Once per session per user
  // (a failure waits a minute before the next try); it never throws.
  if (isAuthenticated &&
      guardEnsuresOwnerAccount(
        isPublicRoute: isPublicRoute,
        isSuperAdmin: superAdmin(firebaseUser),
        emailVerified: effectiveUser?.emailVerified ?? false,
      )) {
    final ensured = await (ensureOwnerAccount ??
        (User user) => FacilityCreatorAccountService.ensureAccountOnce(
              user,
              createOnlyForNewSignups: true,
              timeout: _ensureAccountTimeout,
              clock: clock,
            ))(effectiveUser ?? firebaseUser);
    // An answer cached before the account existed, or before the user's
    // invites were accepted, no longer holds.
    if (ensured) SubscriptionGuardService.routeGuardCache.clear();
  }

  // Maintenance mode: keep users without platform access on subscription; allow trial/active
  // (Previously this blocked everyone except super admins, which trapped trial accounts on /subscription.)
  if (isAuthenticated &&
      !isPublicRoute &&
      !path.startsWith('/subscription') &&
      !path.startsWith(AppRoute.superAdmin) &&
      !superAdmin(firebaseUser)) {
    if (!path.startsWith('/maintenance') && await maintenanceMode) {
      try {
        final maintenanceGate =
            await accessCheck(path).timeout(_accessCheckTimeout);
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
    if (!superAdmin(firebaseUser)) {
      return AppRoute.dashboard;
    }
    return null; // Allow superadmin through
  }

  // Check subscription status for authenticated users (skip for subscription routes)
  if (isAuthenticated && !isPublicRoute && !path.startsWith('/subscription')) {
    final SubscriptionAccessResult subscriptionCheck;
    try {
      // Keyed by uid: the cache used to be shared by whoever signed in next.
      subscriptionCheck = await sharedAccessCheck(firebaseUser.uid);
    } catch (e) {
      // Fail closed to avoid bypassing access control on errors
      if (kDebugMode) {
        print('⚠️ Subscription check error: $e');
      }
      return AppRoute.subscription;
    }

    if (!subscriptionCheck.canAccess &&
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
