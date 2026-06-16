import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:sfcapp/models/facility_creator_account_model.dart';
import 'package:sfcapp/services/facility_creator_account_service.dart';
import 'package:sfcapp/services/facility_service.dart';
import 'package:sfcapp/services/superadmin_service.dart';
import 'app_route.dart';
import '../widgets/subscription_warning_banner.dart';
import '../widgets/subscription_lock_overlay.dart';
import '../services/modern_navigation_service.dart';
import '../services/subscription_guard_service.dart';
import '../widgets/modern_sidebar.dart';
import '../providers/messaging_provider.dart';
import '../widgets/facility_switcher.dart';
import '../theme/app_theme.dart';
import '../services/debug_logger.dart';
import '../screens/late_dashboard_screen.dart';

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

/// Dedicated shell screen for delinquency tab routing.
class DelinquencyShellScreen extends StatelessWidget {
  const DelinquencyShellScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return const LateDashboardScreen();
  }
}

/// Shown when a feature has been disabled via the Super Admin feature flags.
class FeatureDisabledPage extends StatelessWidget {
  final String featureName;
  const FeatureDisabledPage({super.key, required this.featureName});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.block, size: 48, color: Colors.grey),
            const SizedBox(height: 16),
            Text(
              '$featureName is currently unavailable.',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            const Text(
              'This feature has been temporarily disabled by the platform administrator.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.grey),
            ),
            const SizedBox(height: 24),
            TextButton(
              onPressed: () => context.go(AppRoute.dashboard),
              child: const Text('Back to Dashboard'),
            ),
          ],
        ),
      ),
    );
  }
}

/// Periodically checks subscription; redirects to /subscription when trial expired (e.g. stale tab).
class _TrialExpiryChecker extends StatefulWidget {
  final Widget child;

  const _TrialExpiryChecker({required this.child});

  @override
  State<_TrialExpiryChecker> createState() => _TrialExpiryCheckerState();
}

class _TrialExpiryCheckerState extends State<_TrialExpiryChecker> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(minutes: 1), (_) => _checkSubscription());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _checkSubscription() async {
    if (!mounted) return;
    final loc = GoRouter.of(context).routeInformationProvider.value.location ?? '';
    if (loc.startsWith('/subscription')) return;
    try {
      final result = await SubscriptionGuardService.checkAccess(
        currentRoute: loc,
        allowSubscriptionRoutes: true,
      );
      if (!mounted) return;
      if (!result.canAccess && result.redirectRoute != null) {
        context.go(result.redirectRoute!);
      }
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// Sidebar wrapper that disables navigation when subscription is locked
class _SubscriptionAwareSidebar extends StatefulWidget {
  final String currentRoute;
  final Function(String) onNavigate;

  const _SubscriptionAwareSidebar({
    required this.currentRoute,
    required this.onNavigate,
  });

  @override
  State<_SubscriptionAwareSidebar> createState() => _SubscriptionAwareSidebarState();
}

class _SubscriptionAwareSidebarState extends State<_SubscriptionAwareSidebar> {
  bool _isLocked = false;
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _checkSubscription();
  }

  Future<void> _checkSubscription() async {
    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user == null || SuperAdminService.isSuperAdmin()) {
        if (mounted) {
          setState(() {
            _isLocked = false;
            _isLoading = false;
          });
        }
        return;
      }

      final account = await FacilityCreatorAccountService.getAccountByOwnerUid(user.uid);
      final facilities = await FacilityService.getUserFacilities(includeArchived: false, forceRefresh: false);
      final hasAccess = await FacilityCreatorAccountService.hasActiveSubscription(user.uid, facilities: facilities);

      if (mounted) {
        // Pending approval gets its own screen/guard. Don't freeze sidebar interactions here.
        bool isLocked =
            account == null ? true : (account.isPendingApproval ? false : !hasAccess);
        
        setState(() {
          _isLocked = isLocked;
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isLocked = false;
          _isLoading = false;
        });
      }
    }
  }

  void _handleNavigate(String route) {
    // Only allow navigation to subscription page when locked
    if (_isLocked && !route.startsWith('/subscription')) {
      // Show message and redirect to subscription
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Please subscribe to continue using the app.'),
          backgroundColor: AppTheme.error,
          duration: Duration(seconds: 2),
        ),
      );
      widget.onNavigate(AppRoute.subscription);
      return;
    }
    widget.onNavigate(route);
  }

  @override
  Widget build(BuildContext context) {
    return Consumer(
      builder: (context, ref, _) {
        final unread = ref.watch(activeFacilityEmployeeChatUnreadCountProvider);

        // If locked, completely disable sidebar - use AbsorbPointer to block all interactions
        if (_isLocked) {
          return AbsorbPointer(
            absorbing: true,
            child: Opacity(
              opacity: 0.3,
              child: ModernSidebar(
                currentRoute: widget.currentRoute,
                isCollapsed: false,
                onNavigate: (_) {}, // No-op when locked
                employeeChatUnreadCount: unread,
              ),
            ),
          );
        }

        return ModernSidebar(
          currentRoute: widget.currentRoute,
          isCollapsed: false,
          onNavigate: _handleNavigate,
          employeeChatUnreadCount: unread,
        );
      },
    );
  }
}

/// App shell that provides consistent layout (Scaffold + Sidebar + TopBar) for all authenticated routes.
/// Pages inside ShellRoute should NOT use ModernPageWrapper or create their own Scaffold.
class AppShell extends ConsumerWidget {
  final Widget child;
  final bool showSubscriptionBanner;

  const AppShell({
    super.key,
    required this.child,
    this.showSubscriptionBanner = false,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isMobile = MediaQuery.of(context).size.width < 900;
    final currentRoute = GoRouter.of(context).routeInformationProvider.value.location ?? '/dashboard';

    return _TrialExpiryChecker(
      child: SubscriptionLockOverlay(
        child: Scaffold(
        body: Column(
          children: [
            // Always show subscription banner when needed (trial expired, past due, etc.)
            const SubscriptionWarningBanner(),
            Expanded(
              child: Row(
                children: [
                  // Sidebar: give it explicit height from Row so Column+Expanded(ListView) can scroll (pre-2.5 behavior)
                  if (!isMobile)
                    LayoutBuilder(
                      builder: (context, constraints) {
                        return SizedBox(
                          height: constraints.maxHeight,
                          width: 240,
                          child: _SubscriptionAwareSidebar(
                            currentRoute: currentRoute,
                            onNavigate: (route) =>
                                ModernNavigationService.navigateToRoute(
                              context,
                              route,
                            ),
                          ),
                        );
                      },
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
      drawer: isMobile
          ? Drawer(
              width: (MediaQuery.sizeOf(context).width * 0.88)
                  .clamp(280.0, 360.0),
              child: _SubscriptionAwareSidebar(
                currentRoute: currentRoute,
                onNavigate: (route) {
                  Navigator.of(context).pop();
                  ModernNavigationService.navigateToRoute(context, route);
                },
              ),
            )
          : null,
    ),
      ),
    );
  }

  Widget _buildTopBar(BuildContext context, bool isMobile, String currentRoute) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final canNavigateBack = _canNavigateBack(context, currentRoute);
    return Container(
      height: 64,
      decoration: BoxDecoration(
        color: colorScheme.surface,
        border: Border(
          bottom: BorderSide(
            color: theme.dividerColor,
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
          IconButton(
            icon: const Icon(Icons.arrow_back),
            tooltip: 'Back',
            color: colorScheme.onSurfaceVariant,
            onPressed: canNavigateBack
                ? () => _goBack(context, currentRoute)
                : null,
          ),
          FacilitySwitcher(compact: isMobile),
          const SizedBox(width: 16),
          const Spacer(),
          IconButton(
            icon: const Icon(Icons.logout),
            tooltip: 'Sign Out',
            color: colorScheme.onSurfaceVariant,
            onPressed: () => _showLogoutDialog(context),
          ),
        ],
      ),
    );
  }

  bool _canNavigateBack(BuildContext context, String currentRoute) {
    if (GoRouter.of(context).canPop()) {
      return true;
    }
    return !_isDashboardRoute(currentRoute);
  }

  bool _isDashboardRoute(String route) {
    return route == AppRoute.dashboard || route.startsWith('${AppRoute.dashboard}?');
  }

  void _goBack(BuildContext context, String currentRoute) {
    if (GoRouter.of(context).canPop()) {
      context.pop();
      return;
    }
    if (!_isDashboardRoute(currentRoute)) {
      context.go(AppRoute.dashboard);
    }
  }

  void _showLogoutDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Sign Out'),
        content: const Text('Are you sure you want to sign out?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () async {
              Navigator.of(context).pop();
              await FirebaseAuth.instance.signOut();
              if (context.mounted) {
                context.go(AppRoute.login);
              }
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: AppTheme.error,
              foregroundColor: Colors.white,
            ),
            child: const Text('Sign Out'),
          ),
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
            const SizedBox(height: 12),
            OutlinedButton(
              onPressed: () => context.go(AppRoute.units),
              child: const Text('Open Unit List'),
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
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.lock, size: 64, color: Colors.grey),
          const SizedBox(height: 16),
          const Text(
            'Access Codes',
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 8),
          const Text('Select a facility to manage access codes.'),
          const SizedBox(height: 24),
          ElevatedButton(
            onPressed: () {
              ModernNavigationService.navigateToRoute(context, AppRoute.access);
            },
            child: const Text('Select Facility'),
          ),
        ],
      ),
    );
  }
}

/// Landing screen for messaging section
class MessagingLandingScreen extends StatelessWidget {
  const MessagingLandingScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Center(
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
              // #region agent log
              DebugLogger.log(
                hypothesisId: 'H1',
                location: 'route_helpers.dart:MessagingLandingScreen.onPressed',
                message: 'Select Facility button clicked',
                data: {},
              );
              // #endregion
              ModernNavigationService.navigateToRoute(context, AppRoute.messaging);
            },
            child: const Text('Select Facility'),
          ),
        ],
      ),
    );
  }
}

