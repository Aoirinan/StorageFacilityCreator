import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'app_route.dart';
import 'route_guards.dart';
import 'route_helpers.dart';
import 'public_routes.dart';
// Note: Authenticated routes are still in the original app_router.dart
// This will be fully modularized in a follow-up commit

/// Main router provider - modularized version
/// 
/// This router uses modular route definitions for better maintainability.
/// Routes are split into:
/// - Public routes (no auth required)
/// - Authenticated routes (auth + subscription required)
final goRouterProvider = Provider<GoRouter>((ref) {
  final authState = ref.watch(authStateProvider);

  return GoRouter(
    initialLocation: AppRoute.landing,
    debugLogDiagnostics: kDebugMode,
    refreshListenable: GoRouterRefreshStream(FirebaseAuth.instance.authStateChanges()),
    redirect: (context, state) => routeGuard(context, state, ref),
    errorBuilder: (context, state) => NotFoundPage(state: state),
    routes: [
      // Public routes
      ...getPublicRoutes(),
      // Note: Authenticated routes with ShellRoute are still in original app_router.dart
      // They will be extracted to authenticated_routes.dart in next step
    ],
  );
});

