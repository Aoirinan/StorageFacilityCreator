import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../providers/auth_provider.dart';
import '../services/subscription_guard_service.dart';
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
  ProviderRef ref,
) async {
  final authState = ref.watch(authStateProvider);
  final isAuthenticated = authState.asData?.value != null;

  final loc = state.matchedLocation;
  final path = state.uri.path;
  final isLanding = path == '/' || loc == AppRoute.landing || loc.isEmpty;
  final loggingIn = loc == AppRoute.login;

  // Define public routes that don't require authentication
  final publicRoutes = {
    AppRoute.landing,
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
  };

  // Check if current path matches any public route (including with query params)
  final isPublicRoute = publicRoutes.contains(loc) ||
      path == AppRoute.acceptInvite ||
      path.startsWith(AppRoute.acceptInvite + '/') ||
      path.startsWith(AppRoute.acceptInvite + '?') ||
      path.startsWith('${AppRoute.publicFacility}/') ||
      path.startsWith(AppRoute.publicPayment) ||
      path.startsWith(AppRoute.publicRental);

  // Wait for auth state to load
  if (authState.isLoading) return null;

  // Handle unauthenticated users
  if (!isAuthenticated) {
    // Always allow the marketing landing page at root for signed-out users
    if (isLanding) return null;
    return isPublicRoute ? null : AppRoute.login;
  }

  // Redirect authenticated users from landing page to dashboard
  if (isAuthenticated && (loc == AppRoute.landing || path == '/')) {
    return AppRoute.dashboard;
  }

  // Allow authenticated users to access accept-invite (they might be accepting for someone else or themselves)
  if (isAuthenticated &&
      publicRoutes.contains(loc) &&
      loc != AppRoute.acceptInvite) {
    return AppRoute.dashboard;
  }

  // Check subscription status for authenticated users (skip for subscription routes)
  if (isAuthenticated &&
      !isPublicRoute &&
      !path.startsWith('/subscription')) {
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
        _subscriptionCheckCache
          ..result = subscriptionCheck
          ..fetchedAt = DateTime.now();
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

  return null;
}

