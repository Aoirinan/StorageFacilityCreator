import 'dart:async';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'app_route.dart';
import '../widgets/subscription_warning_banner.dart';
import '../services/modern_navigation_service.dart';
import '../widgets/modern_sidebar.dart';
import '../theme/app_theme.dart';

/// Simple wrapper to refresh go_router on auth stream changes.
class GoRouterRefreshStream extends ChangeNotifier {
  GoRouterRefreshStream(Stream<dynamic> stream) {
    _subscription = stream.asBroadcastStream().listen((_) {
      notifyListeners();
    });
  }

  late final StreamSubscription<dynamic> _subscription;

  @override
  void dispose() {
    _subscription.cancel();
    super.dispose();
  }
}

/// Simple friendly 404 page.
class NotFoundPage extends StatelessWidget {
  final GoRouterState state;

  const NotFoundPage({super.key, required this.state});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.search_off, size: 72, color: Colors.grey),
            const SizedBox(height: 12),
            const Text(
              'Page not found',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 8),
            Text(
              state.uri.toString(),
              style: const TextStyle(color: Colors.grey),
            ),
            const SizedBox(height: 24),
            ElevatedButton(
              onPressed: () => context.go(AppRoute.dashboard),
              child: const Text('Back to dashboard'),
            ),
          ],
        ),
      ),
    );
  }
}

/// App shell that provides consistent layout (Scaffold + Sidebar + TopBar) for all authenticated routes.
/// Pages inside ShellRoute should NOT use ModernPageWrapper or create their own Scaffold.
class AppShell extends StatelessWidget {
  final Widget child;
  final bool showSubscriptionBanner;

  const AppShell({
    super.key,
    required this.child,
    this.showSubscriptionBanner = false,
  });

  @override
  Widget build(BuildContext context) {
    final isMobile = MediaQuery.of(context).size.width < 900;
    final currentRoute = GoRouter.of(context).routeInformationProvider.value.location ?? '/dashboard';
    
    return Scaffold(
      body: Column(
        children: [
          if (showSubscriptionBanner) const SubscriptionWarningBanner(),
          Expanded(
            child: Row(
              children: [
                // Sidebar
                if (!isMobile)
                  ModernSidebar(
                    currentRoute: currentRoute,
                    isCollapsed: false,
                    onNavigate: (route) => context.go(route),
                  ),
                
                // Main content
                Expanded(
                  child: Column(
                    children: [
                      // Top bar
                      _buildTopBar(context, isMobile, currentRoute),
                      
                      // Page content
                      Expanded(child: child),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
      drawer: isMobile ? Drawer(
        child: ModernSidebar(
          currentRoute: currentRoute,
          isCollapsed: false,
          onNavigate: (route) {
            Navigator.of(context).pop();
            context.go(route);
          },
        ),
      ) : null,
    );
  }

  Widget _buildTopBar(BuildContext context, bool isMobile, String currentRoute) {
    return Container(
      height: 64,
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border(
          bottom: BorderSide(
            color: AppTheme.borderLight,
            width: 1,
          ),
        ),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Row(
        children: [
          if (isMobile)
            Builder(
              builder: (context) => IconButton(
                icon: const Icon(Icons.menu),
                onPressed: () => Scaffold.of(context).openDrawer(),
              ),
            ),
          const Spacer(),
        ],
      ),
    );
  }
}

/// Landing screen for units section
class UnitsLandingScreen extends StatelessWidget {
  const UnitsLandingScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.storage, size: 64, color: Colors.grey),
            const SizedBox(height: 16),
            const Text(
              'Units & Map',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 8),
            const Text('Select a facility to view units or open the map editor.'),
            const SizedBox(height: 24),
            ElevatedButton(
              onPressed: () {
                ModernNavigationService.navigateToRoute(context, AppRoute.unitsMap);
              },
              child: const Text('Open Map Editor'),
            ),
          ],
        ),
      ),
    );
  }
}

/// Landing screen for access section
class AccessLandingScreen extends StatelessWidget {
  const AccessLandingScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.lock, size: 64, color: Colors.grey),
            const SizedBox(height: 16),
            const Text(
              'Gate Access',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 8),
            const Text('Select a facility to manage gate access codes.'),
            const SizedBox(height: 24),
            ElevatedButton(
              onPressed: () {
                ModernNavigationService.navigateToRoute(context, AppRoute.access);
              },
              child: const Text('Select Facility'),
            ),
          ],
        ),
      ),
    );
  }
}

/// Landing screen for messaging section
class MessagingLandingScreen extends StatelessWidget {
  const MessagingLandingScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.message, size: 64, color: Colors.grey),
            const SizedBox(height: 16),
            const Text(
              'Team Messaging',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 8),
            const Text('Select a facility to open messaging.'),
            const SizedBox(height: 24),
            ElevatedButton(
              onPressed: () {
                ModernNavigationService.navigateToRoute(context, AppRoute.messaging);
              },
              child: const Text('Select Facility'),
            ),
          ],
        ),
      ),
    );
  }
}

