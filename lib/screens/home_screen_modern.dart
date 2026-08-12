import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:go_router/go_router.dart';
import '../providers/auth_provider.dart';
import '../services/debug_logger.dart';
import '../providers/facility_provider.dart';
import '../providers/active_facility_provider.dart';
import '../providers/search_provider.dart' as search;
import '../providers/dashboard_provider.dart';
import '../models/facility_model.dart';
import '../services/search_service.dart';
import '../services/tenant_service.dart';
import '../services/facility_service.dart';
import '../widgets/modern_sidebar.dart';
import '../widgets/dashboard/metric_card.dart';
import '../widgets/dashboard/donut_chart.dart';
import '../widgets/dashboard/activity_feed.dart' as activity;
import '../theme/app_theme.dart';
import '../services/modern_navigation_service.dart';
import '../services/home_button_service.dart';
import '../router/app_router.dart';
import '../router/app_route.dart';
import '../widgets/language_selector.dart';
import '../widgets/facility_switcher.dart';
import 'auth/login_screen.dart';
import 'client_detail_screen.dart';
import 'facility_creation_wizard.dart';
import 'facility_management_screen.dart';
import 'client_list_screen.dart';
import 'facility_map_editor_screen.dart';
import 'payment_list_screen.dart';
import 'reminder_list_screen.dart';
import 'messaging_screen.dart';
import 'gate_access_screen.dart';
import 'financial_reports_screen.dart';
import 'tenant_creation_screen.dart';
import 'subscription_test_screen.dart';
import 'settings_screen.dart';
import 'insurance_screen.dart';
import 'yield_management_screen.dart';
import 'ai_assistant_screen.dart';
import '../services/facility_creator_account_service.dart';
import '../services/superadmin_service.dart';
import '../models/facility_creator_account_model.dart';
import 'home_screen_modern_helper.dart';
import '../widgets/keyboard_scrollable.dart';
import '../utils/error_message_helper.dart';
import '../services/facility_stats_service.dart';
import '../services/dashboard_owner_tips_service.dart';
import '../widgets/dashboard_owner_tips_dialog.dart';

class HomeScreenModern extends ConsumerWidget {
  const HomeScreenModern({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final authState = ref.watch(authStateProvider);

    return authState.when(
      data: (user) {
        if (user == null) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (context.mounted) {
              context.go(AppRoute.login);
            }
          });
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }
        return _HomeScreenModernContent(user: user);
      },
      loading: () => const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      ),
      error: (error, stackTrace) => Scaffold(
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.error, size: 64, color: AppTheme.error),
              const SizedBox(height: 16),
              const Text('Authentication Error'),
              const SizedBox(height: 8),
              Text(ErrorMessageHelper.getUserFriendlyMessage(error)),
              const SizedBox(height: 16),
              ElevatedButton(
                onPressed: () {
                  context.go(AppRoute.login);
                },
                child: const Text('Back to Login'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _HomeScreenModernContent extends ConsumerStatefulWidget {
  final User user;

  const _HomeScreenModernContent({required this.user});

  @override
  ConsumerState<_HomeScreenModernContent> createState() => _HomeScreenModernContentState();
}

class _HomeScreenModernContentState extends ConsumerState<_HomeScreenModernContent> {
  String _currentRoute = '/dashboard';
  final _searchController = TextEditingController();
  bool _showSearchResults = false;
  bool _sidebarCollapsed = false;
  Timer? _searchDebounce;
  bool _ownerDashboardTipsHandled = false;

  @override
  void initState() {
    super.initState();
    // Defer visibility change until after first frame to avoid setState during build.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        HomeButtonService.instance.show();
      }
    });
    _searchController.addListener(_onSearchChanged);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final location =
        GoRouter.of(context).routeInformationProvider.value.location ?? _currentRoute;
    if (_currentRoute != location) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        setState(() {
          _currentRoute = location;
        });
      });
    }
  }

  @override
  void dispose() {
    _searchDebounce?.cancel();
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _recomputeAllStats(BuildContext context) async {
    try {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Syncing facility counts…')),
      );
      await FacilityStatsService.recomputeAllFacilitiesStats();
      if (!context.mounted) return;
      ref.invalidate(dashboardStatsProvider);
      setState(() {});
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Counts synced. Dashboard, delinquency, and facility cards will show matching numbers.'),
          backgroundColor: AppTheme.success,
        ),
      );
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(ErrorMessageHelper.getUserFriendlyMessage(e)),
          backgroundColor: AppTheme.error,
        ),
      );
    }
  }

  void _onSearchChanged() {
    final query = _searchController.text.trim();
    _searchDebounce?.cancel();
    _searchDebounce = Timer(const Duration(milliseconds: 200), () {
      ref.read(search.searchQueryProvider.notifier).state = query;
      ref.read(search.searchStateProvider(widget.user.uid).notifier).updateQuery(query);
      if (mounted) {
        setState(() {
          _showSearchResults = query.isNotEmpty;
        });
      }
      // #region agent log
      DebugLogger.log(
        hypothesisId: 'H4',
        location: 'home_screen_modern.dart:_onSearchChanged',
        message: 'Search updated',
        data: {'queryLength': query.length},
      );
      // #endregion
    });
  }

  void _handleNavigation(String route) {
    // Always log to console (even in release mode for debugging)
    if (kDebugMode) {
      print('🧭 _handleNavigation called with route: $route');
    }
    setState(() {
      _currentRoute = route;
    });
    ModernNavigationService.navigateToRoute(context, route);
  }

  // Helper to get current route from Navigator
  String _getCurrentRoute() {
    final route = ModalRoute.of(context);
    if (route == null) return '/dashboard';
    
    final routeName = route.settings.name;
    if (routeName != null) {
      return routeName;
    }
    
    // Fallback: check if we're on dashboard
    if (Navigator.of(context).canPop()) {
      return '/dashboard'; // We're on a pushed route
    }
    return '/dashboard';
  }

  void _showNoFacilitiesDialog(BuildContext context, {required String featureName}) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('No Facilities'),
        content: Text('You need to create a facility before using $featureName.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () {
              Navigator.of(context).pop();
              _handleNewFacilityPressed(context);
            },
            child: const Text('Create Facility'),
          ),
        ],
      ),
    );
  }

  void _handleNewFacilityPressed(BuildContext context) async {
    // Check subscription status before allowing facility creation
    try {
      final account = await FacilityCreatorAccountService.getOrCreateAccountForCurrentUser();
      ref.invalidate(userFacilitiesProvider(widget.user.uid));
      // Check if user has facilities
      final facilities = await ref.read(userFacilitiesProvider(widget.user.uid).future);

      // Check if user is on trial and already has a facility
      if (account.subscriptionStatus == SubscriptionStatus.trialing && facilities.length >= 1) {
        // Show upgrade dialog for trial users
        showDialog(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Upgrade Required'),
            content: const Text(
              'You are currently on a free trial and can only create one facility. '
              'To create additional facilities, please upgrade to a paid subscription.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('Cancel'),
              ),
              ElevatedButton(
                onPressed: () {
                  Navigator.of(context).pop();
                  context.go(AppRoute.subscription);
                },
                child: const Text('Upgrade'),
              ),
            ],
          ),
        );
        return;
      }

      // Allow facility creation
      context.go(AppRoute.facilityNew);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error: $e'),
            backgroundColor: AppTheme.error,
          ),
        );
      }
    }
  }

  Future<void> _processOwnerDashboardTips(List<FacilityModel> facilities) async {
    if (!mounted || _ownerDashboardTipsHandled) return;
    final uid = widget.user.uid;
    final teamOnly = facilities.isNotEmpty &&
        facilities.every((f) => f.showsAsTeamMemberForViewer(uid));
    if (teamOnly) {
      _ownerDashboardTipsHandled = true;
      return;
    }
    if (await DashboardOwnerTipsService.isDisabled()) {
      _ownerDashboardTipsHandled = true;
      return;
    }
    if (!mounted) return;
    _ownerDashboardTipsHandled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      final result = await showDialog<DashboardOwnerTipsDialogResult>(
        context: context,
        barrierDismissible: true,
        builder: (context) => const DashboardOwnerTipsDialog(),
      );
      if (!mounted) return;
      if (result?.neverShowAgain == true) {
        await DashboardOwnerTipsService.setDisabled(true);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final facilitiesAsync = ref.watch(userFacilitiesProvider(widget.user.uid));
    facilitiesAsync.whenData((facilities) {
      unawaited(_processOwnerDashboardTips(facilities));
    });
    return _buildDashboard();
  }

  Widget _buildTopBar(BuildContext context, bool isMobile) {
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      height: 64,
      decoration: BoxDecoration(
        color: colorScheme.surface,
        border: Border(
          bottom: BorderSide(
            color: colorScheme.outline,
            width: 1,
          ),
        ),
      ),
      padding: EdgeInsets.symmetric(
        horizontal: isMobile ? 12 : 24,
      ),
      child: Row(
        children: [
          if (isMobile)
            Builder(
              builder: (context) => IconButton(
                icon: const Icon(Icons.menu),
                tooltip: 'Open navigation menu',
                onPressed: () => Scaffold.of(context).openDrawer(),
              ),
            ),
          Text(
            'SFC',
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.w700,
              color: colorScheme.primary,
              letterSpacing: -0.5,
            ),
          ),
          const SizedBox(width: 24),
          
          // Search bar
          Expanded(
            child: Container(
              constraints: const BoxConstraints(maxWidth: 600),
              child: TextField(
                controller: _searchController,
                onChanged: (value) {
                  // Trigger search immediately when user types
                  _onSearchChanged();
                },
                decoration: InputDecoration(
                  hintText: 'Search tenants, units, or facilities...',
                  prefixIcon: const Icon(Icons.search),
                  suffixIcon: _searchController.text.isNotEmpty
                      ? IconButton(
                          icon: const Icon(Icons.clear),
                          onPressed: () {
                            _searchController.clear();
                            setState(() {
                              _showSearchResults = false;
                            });
                            // Clear search query
                            ref.read(search.searchQueryProvider.notifier).state = '';
                            ref.read(search.searchStateProvider(widget.user.uid).notifier).updateQuery('');
                          },
                        )
                      : null,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: BorderSide(color: colorScheme.outline),
                  ),
                  filled: true,
                  fillColor: colorScheme.surfaceContainerHighest,
                  contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                ),
              ),
            ),
          ),
          
          const Spacer(),
          
          // Facility Switcher
          const FacilitySwitcher(compact: false),
          const SizedBox(width: 8),
          // Sync counts (recompute occupancy/tenant counts for all facilities)
          Tooltip(
            message: 'Recompute occupancy, tenant counts, and past-due totals for all facilities',
            child: IconButton(
              onPressed: () => _recomputeAllStats(context),
              icon: const Icon(Icons.refresh, size: 20),
              tooltip: 'Sync counts',
            ),
          ),
          const SizedBox(width: 16),
          
          // Language selector
          const LanguageSelector(),
          const SizedBox(width: 12),
          
          // User menu
          PopupMenuButton<String>(
            icon: CircleAvatar(
              backgroundColor: AppTheme.primaryBlue.withOpacity(0.1),
              child: Icon(
                Icons.person,
                color: AppTheme.primaryBlue,
              ),
            ),
            onSelected: (value) {
              if (value == 'logout') {
                _showLogoutDialog(context);
              } else if (value == 'subscription') {
                context.go(AppRoute.subscription);
              }
            },
            itemBuilder: (context) => [
              PopupMenuItem(
                value: 'profile',
                child: Row(
                  children: [
                    const Icon(Icons.person, size: 20),
                    const SizedBox(width: 8),
                    Text(widget.user.email ?? 'Profile'),
                  ],
                ),
              ),
              const PopupMenuItem(
                value: 'subscription',
                child: Row(
                  children: [
                    Icon(Icons.payment, size: 20),
                    SizedBox(width: 8),
                    Text('Subscription & Payments'),
                  ],
                ),
              ),
              const PopupMenuItem(
                value: 'logout',
                child: Row(
                  children: [
                    Icon(Icons.logout, size: 20),
                    SizedBox(width: 8),
                    Text('Sign Out'),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildDashboard() {
    final dashboardStats = ref.watch(dashboardStatsProvider);
    final facilitiesAsync = ref.watch(userFacilitiesProvider(widget.user.uid));
    final hasFacilities = facilitiesAsync.when(
          data: (list) => list.isNotEmpty,
          loading: () => false,
          error: (_, __) => false,
        );
    final isMobile = MediaQuery.of(context).size.width < 900;

    return SingleChildScrollView(
      padding: EdgeInsets.all(isMobile ? 16 : 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Welcome section (includes "Create your first facility" CTA when empty)
          _buildWelcomeSection(),
          const SizedBox(height: 16),
          // Sync counts only when user has facilities; otherwise show get-started checklist
          if (hasFacilities) _buildDashboardSyncRow(context),
          if (!hasFacilities) ...[
            _buildGetStartedChecklist(context),
            const SizedBox(height: 24),
          ],
          if (hasFacilities) const SizedBox(height: 24),
          
          // Metrics grid
          dashboardStats.when(
            data: (stats) => _buildMetricsGrid(stats),
            loading: () => const Center(
              child: Padding(
                padding: EdgeInsets.all(48.0),
                child: CircularProgressIndicator(),
              ),
            ),
            error: (error, stack) => _buildErrorWidget(error),
          ),
          
          const SizedBox(height: 24),
          
          // Charts and activity section
          dashboardStats.when(
            data: (stats) => _buildChartsSection(stats),
            loading: () => const SizedBox.shrink(),
            error: (_, __) => const SizedBox.shrink(),
          ),
          
          const SizedBox(height: 24),
          
          // Critical items section (delinquent tenants & upcoming move-outs)
          dashboardStats.when(
            data: (stats) => _buildCriticalItemsSection(stats),
            loading: () => const SizedBox.shrink(),
            error: (_, __) => const SizedBox.shrink(),
          ),
          
          const SizedBox(height: 24),
          
          // Quick actions grid
          _buildQuickActionsGrid(),
        ],
      ),
    );
  }

  Widget _buildWelcomeSection() {
    final facilitiesAsync = ref.watch(userFacilitiesProvider(widget.user.uid));
    final activeFacilityId = ref.watch(activeFacilityIdProvider).whenOrNull(data: (d) => d);

    return facilitiesAsync.when(
      data: (facilities) {
        final colorScheme = Theme.of(context).colorScheme;

        // Empty state: prompt to create first facility
        if (facilities.isEmpty) {
          return Card(
            elevation: 0,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
              side: BorderSide(color: colorScheme.outline, width: 1),
            ),
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Row(
                children: [
                  Container(
                    width: 56,
                    height: 56,
                    decoration: BoxDecoration(
                      color: colorScheme.primary.withOpacity(0.1),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Icon(
                      Icons.add_business,
                      color: colorScheme.primary,
                      size: 28,
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Get started',
                          style: TextStyle(
                            fontSize: 14,
                            color: colorScheme.onSurfaceVariant,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          'Create your first facility to get started',
                          style: TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.w700,
                            color: colorScheme.onSurface,
                            letterSpacing: -0.5,
                          ),
                        ),
                        if (widget.user.email != null) ...[
                          const SizedBox(height: 4),
                          Text(
                            widget.user.email!,
                            style: TextStyle(
                              fontSize: 14,
                              color: colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  ElevatedButton.icon(
                    onPressed: () => _handleNewFacilityPressed(context),
                    icon: const Icon(Icons.add_business, size: 20),
                    label: const Text('Create Facility'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppTheme.primaryBlue,
                      foregroundColor: AppTheme.textOnDark,
                      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
                    ),
                  ),
                ],
              ),
            ),
          );
        }

        String facilityName;
        FacilityModel? activeFacility;
        if (activeFacilityId == null) {
          facilityName = 'All Facilities';
        } else {
          activeFacility = facilities.firstWhere(
            (f) => f.id == activeFacilityId,
            orElse: () => facilities.first,
          );
          facilityName = activeFacility.name;
        }
        final showTeamMemberWelcome = activeFacility != null &&
            activeFacility.showsAsTeamMemberForViewer(widget.user.uid);
        return Card(
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: BorderSide(color: colorScheme.outline, width: 1),
          ),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Row(
              children: [
                Container(
                  width: 56,
                  height: 56,
                  decoration: BoxDecoration(
                    color: colorScheme.primary.withOpacity(0.1),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(
                    Icons.dashboard,
                    color: colorScheme.primary,
                    size: 28,
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Welcome back!',
                        style: TextStyle(
                          fontSize: 14,
                          color: colorScheme.onSurfaceVariant,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        facilityName,
                        style: TextStyle(
                          fontSize: 24,
                          fontWeight: FontWeight.w700,
                          color: colorScheme.onSurface,
                          letterSpacing: -0.5,
                        ),
                      ),
                      if (showTeamMemberWelcome) ...[
                        const SizedBox(height: 8),
                        Row(
                          children: [
                            Icon(
                              Icons.groups_outlined,
                              size: 18,
                              color: colorScheme.primary,
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                'You’re a team member at this facility (not the owner).',
                                style: TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w500,
                                  color: colorScheme.onSurfaceVariant,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ],
                      if (activeFacilityId == null && facilities.isNotEmpty) ...[
                        Builder(
                          builder: (context) {
                            final teamCount = facilities
                                .where(
                                    (f) => f.showsAsTeamMemberForViewer(widget.user.uid))
                                .length;
                            if (teamCount == 0) return const SizedBox.shrink();
                            return Padding(
                              padding: const EdgeInsets.only(top: 8),
                              child: Row(
                                children: [
                                  Icon(
                                    Icons.groups_outlined,
                                    size: 18,
                                    color: colorScheme.primary,
                                  ),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: Text(
                                      teamCount == facilities.length
                                          ? 'You’re a team member on all $teamCount ${teamCount == 1 ? 'facility' : 'facilities'} shown here.'
                                          : 'Team member on $teamCount of ${facilities.length} facilities — check the facility menu for which ones.',
                                      style: TextStyle(
                                        fontSize: 13,
                                        fontWeight: FontWeight.w500,
                                        color: colorScheme.onSurfaceVariant,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            );
                          },
                        ),
                      ],
                      if (widget.user.email != null) ...[
                        const SizedBox(height: 4),
                        Text(
                          widget.user.email!,
                          style: TextStyle(
                            fontSize: 14,
                            color: colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
      loading: () => const SizedBox.shrink(),
      error: (_, __) => const SizedBox.shrink(),
    );
  }

  /// Get-started checklist shown when user has no facilities (first-time onboarding).
  Widget _buildGetStartedChecklist(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: colorScheme.outline, width: 1),
      ),
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.checklist, color: colorScheme.primary, size: 24),
                const SizedBox(width: 12),
                Text(
                  'Get started',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                    color: colorScheme.onSurface,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            _GetStartedStep(
              number: 1,
              title: 'Create your first facility',
              subtitle: 'Add name, address, and billing settings.',
              onTap: () => _handleNewFacilityPressed(context),
            ),
            const SizedBox(height: 12),
            _GetStartedStep(
              number: 2,
              title: 'Add units',
              subtitle: 'Use Unit Map or Unit List from the sidebar.',
              onTap: () => _showNoFacilitiesDialog(context, featureName: 'units'),
            ),
            const SizedBox(height: 12),
            _GetStartedStep(
              number: 3,
              title: 'Add a tenant',
              subtitle: 'Use Move-In Wizard or Tenants → Create Tenant.',
              onTap: () => _showNoFacilitiesDialog(context, featureName: 'tenants'),
            ),
          ],
        ),
      ),
    );
  }

  /// Sync counts button on Dashboard – same action as Facilities screen and top bar (all in unison).
  Widget _buildDashboardSyncRow(BuildContext context) {
    return Align(
      alignment: Alignment.centerLeft,
      child: Tooltip(
        message: 'Recompute occupancy, tenant counts, and past-due totals for all facilities',
        child: TextButton.icon(
          onPressed: () => _recomputeAllStats(context),
          icon: const Icon(Icons.refresh, size: 18),
          label: const Text('Sync counts'),
        ),
      ),
    );
  }

  Widget _buildMetricsGrid(DashboardStats stats) {
    final activeFacilityId = ref.watch(activeFacilityIdProvider).whenOrNull(data: (d) => d);
    final linkedFacilityCount = ref.watch(userFacilitiesProvider(widget.user.uid)).whenOrNull(data: (l) => l.length) ?? 0;
    final aggregateAll = activeFacilityId == null;

    return LayoutBuilder(
      builder: (context, constraints) {
        int crossAxisCount;
        if (constraints.maxWidth < 600) {
          crossAxisCount = 1;
        } else if (constraints.maxWidth < 900) {
          crossAxisCount = 2;
        } else if (constraints.maxWidth < 1200) {
          crossAxisCount = 2;
        } else {
          crossAxisCount = 4;
        }

        final cs = Theme.of(context).colorScheme;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (aggregateAll && linkedFacilityCount > 1)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Text(
                  'Totals combine all ${stats.totalFacilities} facilities you can select in the facility menu (your account only). Pick one facility to see its numbers alone.',
                  style: TextStyle(
                    fontSize: 13,
                    height: 1.35,
                    color: cs.onSurfaceVariant,
                  ),
                ),
              ),
            GridView.count(
          crossAxisCount: crossAxisCount,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          mainAxisSpacing: 16,
          crossAxisSpacing: 16,
          childAspectRatio: 1.2,
          children: [
            MetricCard(
              title: 'Total Tenants',
              value: stats.totalTenants.toString(),
              subtitle: 'Active tenants',
              icon: Icons.people,
              color: AppTheme.primaryBlue,
            ),
            MetricCard(
              title: 'Total Units',
              value: stats.totalUnits.toString(),
              subtitle:
                  '${stats.occupiedUnits} occupied · ${stats.availableUnits} vacant',
              icon: Icons.home_work,
              color: AppTheme.info,
            ),
            MetricCard(
              title: 'Monthly Revenue',
              value: '\$${stats.monthlyRevenue.toStringAsFixed(0)}',
              subtitle: stats.autopayMonthlyRevenue > 0
                  ? 'Recurring · \$${stats.autopayMonthlyRevenue.toStringAsFixed(0)} on autopay'
                  : 'Recurring revenue',
              icon: Icons.attach_money,
              color: AppTheme.success,
            ),
            MetricCard(
              title: 'Past Due',
              value: stats.pastDueCount.toString(),
              subtitle: 'Tenants behind on rent',
              icon: Icons.warning,
              color: stats.pastDueCount > 0 ? AppTheme.error : AppTheme.success,
              onTap: stats.pastDueCount > 0
                  ? () => ModernNavigationService.navigateToRoute(context, '/delinquency')
                  : null,
            ),
          ],
        ),
          ],
        );
      },
    );
  }

  Widget _buildChartsSection(DashboardStats stats) {
    final activeFacilityId = ref.watch(activeFacilityIdProvider).whenOrNull(data: (d) => d);
    final linkedFacilityCount = ref.watch(userFacilitiesProvider(widget.user.uid)).whenOrNull(data: (l) => l.length) ?? 0;
    final activities = _generateSampleActivities(
      stats,
      aggregateAllLinkedFacilities: activeFacilityId == null,
      linkedFacilityCount: linkedFacilityCount,
    );

    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth < 900) {
          // Stack vertically on mobile
          return Column(
            children: [
              _buildOccupancyCard(stats),
              const SizedBox(height: 16),
              activity.ActivityFeed(
                activities: activities,
              ),
            ],
          );
        }
        
        // Side by side on desktop
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              flex: 2,
              child: _buildOccupancyCard(stats),
            ),
            const SizedBox(width: 16),
          Expanded(
            flex: 3,
            child: activity.ActivityFeed(
              activities: activities,
            ),
          ),
          ],
        );
      },
    );
  }

  Widget _buildOccupancyCard(DashboardStats stats) {
    final colorScheme = Theme.of(context).colorScheme;
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: colorScheme.outline, width: 1),
      ),
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'OCCUPANCY RATE',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: colorScheme.onSurfaceVariant,
                letterSpacing: 0.5,
              ),
            ),
            const SizedBox(height: 20),
            Center(
              child: DonutChart(
                value: stats.occupancyRate,
                label: 'Occupied',
                color: colorScheme.primary,
                size: 160,
              ),
            ),
            const SizedBox(height: 16),
            Center(
              child: Text(
                '${(stats.occupancyRate * 100).toStringAsFixed(1)}%',
                style: TextStyle(
                  fontSize: 32,
                  fontWeight: FontWeight.w700,
                  color: colorScheme.onSurface,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  List<activity.ActivityItem> _generateSampleActivities(
    DashboardStats stats, {
    required bool aggregateAllLinkedFacilities,
    required int linkedFacilityCount,
  }) {
    final activities = <activity.ActivityItem>[];
    final multiFacility = aggregateAllLinkedFacilities && linkedFacilityCount > 1;
    final tenantSubtitle = multiFacility
        ? '${stats.totalTenants} active tenants across $linkedFacilityCount facilities in your account'
        : '${stats.totalTenants} active tenant${stats.totalTenants == 1 ? '' : 's'}';

    if (stats.totalTenants > 0) {
      activities.add(activity.ActivityItem(
        title: 'Tenants',
        subtitle: tenantSubtitle,
        icon: Icons.people,
        iconColor: AppTheme.primaryBlue,
        timestamp: DateTime.now().subtract(const Duration(minutes: 5)),
      ));
    }
    
    if (stats.totalUnits > 0) {
      activities.add(activity.ActivityItem(
        title: 'Total Units',
        subtitle: multiFacility
            ? '${stats.occupiedUnits} occupied · ${stats.availableUnits} vacant · ${stats.totalUnits} total (combined)'
            : '${stats.occupiedUnits} occupied · ${stats.availableUnits} vacant · ${stats.totalUnits} total',
        icon: Icons.home_work,
        iconColor: AppTheme.info,
        timestamp: DateTime.now().subtract(const Duration(minutes: 10)),
      ));
    }
    
    if (stats.monthlyRevenue > 0) {
      final ap = stats.autopayMonthlyRevenue;
      activities.add(activity.ActivityItem(
        title: 'Monthly Revenue',
        subtitle: ap > 0
            ? '\$${stats.monthlyRevenue.toStringAsFixed(0)} scheduled · \$${ap.toStringAsFixed(0)} on autopay'
            : '\$${stats.monthlyRevenue.toStringAsFixed(0)} recurring revenue',
        icon: Icons.attach_money,
        iconColor: AppTheme.success,
        timestamp: DateTime.now().subtract(const Duration(hours: 1)),
      ));
    }
    
    if (stats.pastDueCount > 0) {
      activities.add(activity.ActivityItem(
        title: 'Past Due Payments',
        subtitle: '${stats.pastDueCount} payments need attention',
        icon: Icons.warning,
        iconColor: AppTheme.error,
        timestamp: DateTime.now().subtract(const Duration(hours: 2)),
      ));
    }
    
    return activities;
  }

  Widget _buildQuickActionsGrid() {
    final isMobile = MediaQuery.of(context).size.width < 600;
    
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Quick Actions',
          style: TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.w600,
            color: Theme.of(context).colorScheme.onSurface,
          ),
        ),
        const SizedBox(height: 16),
        LayoutBuilder(
          builder: (context, constraints) {
            int crossAxisCount;
            if (constraints.maxWidth < 600) {
              crossAxisCount = 2;
            } else if (constraints.maxWidth < 900) {
              crossAxisCount = 3;
            } else {
              crossAxisCount = 4;
            }

            return GridView.count(
              crossAxisCount: crossAxisCount,
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              mainAxisSpacing: 12,
              crossAxisSpacing: 12,
              childAspectRatio: 1.5,
              children: [
                _buildQuickActionCard(
                  'Tenants',
                  Icons.people,
                  AppTheme.primaryBlue,
                  () => ModernNavigationService.navigateToRoute(context, '/tenants'),
                ),
                _buildQuickActionCard(
                  'Units',
                  Icons.home_work,
                  AppTheme.info,
                  () => _handleNavigation('/units'),
                ),
                _buildQuickActionCard(
                  'Billing',
                  Icons.payment,
                  AppTheme.success,
                  () => ModernNavigationService.navigateToRoute(context, '/billing'),
                ),
                _buildQuickActionCard(
                  'Reports',
                  Icons.assessment,
                  AppTheme.warning,
                  () => ModernNavigationService.navigateToRoute(context, '/reports'),
                ),
                _buildQuickActionCard(
                  'Contracts\n& E-Sign',
                  Icons.draw_outlined,
                  AppTheme.primaryBlue,
                  () => ModernNavigationService.navigateToRoute(context, '/contracts'),
                ),
                _buildQuickActionCard(
                  'Integrations',
                  Icons.integration_instructions,
                  AppTheme.info,
                  () => context.go(AppRoute.subscription),
                ),
              ],
            );
          },
        ),
      ],
    );
  }

  Widget _buildQuickActionCard(String label, IconData icon, Color color, VoidCallback onTap) {
    final colorScheme = Theme.of(context).colorScheme;
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: colorScheme.outline, width: 1),
      ),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, color: color, size: 32),
              const SizedBox(height: 8),
              Text(
                label,
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: colorScheme.onSurface,
                  height: 1.2,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSearchResults(AsyncValue<List<SearchResult>> searchState) {
    return searchState.when(
      data: (results) {
        if (results.isEmpty) {
          final cs = Theme.of(context).colorScheme;
          return Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.search_off, size: 64, color: cs.onSurfaceVariant),
                const SizedBox(height: 16),
                Text(
                  'No results found',
                  style: TextStyle(
                    fontSize: 18,
                    color: cs.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          );
        }

        final cs = Theme.of(context).colorScheme;
        return ListView.builder(
          padding: const EdgeInsets.all(16),
          itemCount: results.length,
          itemBuilder: (context, index) {
            final result = results[index];
            return Card(
              margin: const EdgeInsets.only(bottom: 8),
              child: ListTile(
                leading: Icon(
                  result.type == 'tenant' ? Icons.person : Icons.business,
                  color: cs.primary,
                ),
                title: Text(result.title),
                subtitle: Text(result.subtitle ?? ''),
                trailing: const Icon(Icons.arrow_forward_ios, size: 16),
                onTap: () => _onSearchResultTap(result),
              ),
            );
          },
        );
      },
      loading: () {
        final cs = Theme.of(context).colorScheme;
        return Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const CircularProgressIndicator(),
              const SizedBox(height: 16),
              Text(
                'Searching...',
                style: TextStyle(
                  color: cs.onSurfaceVariant,
                  fontSize: 14,
                ),
              ),
            ],
          ),
        );
      },
      error: (error, stack) {
        final cs = Theme.of(context).colorScheme;
        return Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.error_outline, size: 64, color: cs.error),
              const SizedBox(height: 16),
              Text(
                'Error searching',
                style: TextStyle(
                  fontSize: 18,
                  color: cs.onSurface,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 8),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 32),
                child: Text(
                  ErrorMessageHelper.getUserFriendlyMessage(error),
                  style: TextStyle(
                    fontSize: 14,
                    color: cs.onSurfaceVariant,
                  ),
                  textAlign: TextAlign.center,
                ),
              ),
              const SizedBox(height: 16),
              ElevatedButton.icon(
                onPressed: () {
                  // Retry search
                  final query = _searchController.text.trim();
                  if (query.isNotEmpty) {
                    ref.read(search.searchStateProvider(widget.user.uid).notifier).updateQuery(query);
                  }
                },
                icon: const Icon(Icons.refresh),
                label: const Text('Retry'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: cs.primary,
                  foregroundColor: cs.onPrimary,
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  void _onSearchResultTap(SearchResult result) async {
    if (result.type == 'tenant') {
      await _navigateToTenantFromSearch(result);
    } else if (result.type == 'facility') {
      await _navigateToFacilityFromSearch(result);
    }
  }

  Future<void> _navigateToTenantFromSearch(SearchResult result) async {
    try {
      final facilityId = result.data['facilityId'] as String?;
      if (facilityId == null || facilityId.isEmpty) {
        if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: const Text('Unable to locate tenant - facility ID missing'),
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
          );
        }
        return;
      }

      final tenant = await TenantService.getTenantById(facilityId, result.id);
      if (!mounted) return;

      if (tenant == null) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Tenant not found'),
              backgroundColor: AppTheme.warning,
            ),
          );
        }
        return;
      }

      if (context.mounted) {
        context.push(AppRoute.tenantDetail, extra: tenant);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error: $e'),
            backgroundColor: AppTheme.error,
          ),
        );
      }
    }
  }

  Future<void> _navigateToFacilityFromSearch(SearchResult result) async {
    try {
      final facility = await FacilityService.getFacility(result.id);
      if (!mounted) return;

      if (facility == null) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Facility not found'),
              backgroundColor: AppTheme.warning,
            ),
          );
        }
        return;
      }

      context.go(AppRoute.tenants);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error: $e'),
            backgroundColor: AppTheme.error,
          ),
        );
      }
    }
  }

  Widget _buildErrorWidget(Object error) {
    final cs = Theme.of(context).colorScheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Center(
          child: Column(
            children: [
              Icon(Icons.error_outline, size: 48, color: cs.error),
              const SizedBox(height: 16),
              Text(
                'Error loading dashboard',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: cs.onSurface,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                ErrorMessageHelper.getUserFriendlyMessage(error),
                style: TextStyle(
                  fontSize: 14,
                  color: cs.onSurfaceVariant,
                ),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      ),
    );
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
              final authService = ref.read(authServiceProvider);
              await authService.signOut();
              if (mounted) {
                context.go(AppRoute.login);
              }
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
              foregroundColor: Theme.of(context).colorScheme.onError,
            ),
            child: const Text('Sign Out'),
          ),
        ],
      ),
    );
  }

  Widget _buildCriticalItemsSection(DashboardStats stats) {
    final isMobile = MediaQuery.of(context).size.width < 900;
    final hasDelinquent = stats.topDelinquentTenants.isNotEmpty;
    final hasMoveOuts = stats.upcomingMoveOuts.isNotEmpty;

    if (!hasDelinquent && !hasMoveOuts) {
      return const SizedBox.shrink();
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth < 900) {
          // Stack vertically on mobile
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (hasDelinquent) ...[
                _buildDelinquentTenantsCard(stats.topDelinquentTenants),
                const SizedBox(height: 16),
              ],
              if (hasMoveOuts) ...[
                _buildUpcomingMoveOutsCard(stats.upcomingMoveOuts),
              ],
            ],
          );
        }

        // Side by side on desktop
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (hasDelinquent)
              Expanded(
                child: _buildDelinquentTenantsCard(stats.topDelinquentTenants),
              ),
            if (hasDelinquent && hasMoveOuts) const SizedBox(width: 16),
            if (hasMoveOuts)
              Expanded(
                child: _buildUpcomingMoveOutsCard(stats.upcomingMoveOuts),
              ),
          ],
        );
      },
    );
  }

  Widget _buildDelinquentTenantsCard(List<TopDelinquentTenant> tenants) {
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: AppTheme.error.withOpacity(0.3), width: 1),
      ),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.warning, color: AppTheme.error, size: 24),
                const SizedBox(width: 8),
                Text(
                  'Top Delinquent Tenants',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w600,
                    color: Theme.of(context).colorScheme.onSurface,
                  ),
                ),
                const Spacer(),
                TextButton(
                  onPressed: () => ModernNavigationService.navigateToRoute(context, '/delinquency'),
                  child: const Text('View All'),
                ),
              ],
            ),
            const SizedBox(height: 16),
            if (tenants.isEmpty)
              Padding(
                padding: const EdgeInsets.all(16.0),
                child: Center(
                  child: Text(
                    'No delinquent tenants',
                    style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
                  ),
                ),
              )
            else
              ...tenants.map((tenant) => _buildDelinquentTenantItem(tenant)),
          ],
        ),
      ),
    );
  }

  Widget _buildDelinquentTenantItem(TopDelinquentTenant tenant) {
    return InkWell(
      onTap: () {
        // Navigate to tenant detail
        context.push('/tenants/detail?tenantId=${tenant.tenantId}&facilityId=${tenant.facilityId}');
      },
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
        child: Row(
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: AppTheme.error.withOpacity(0.1),
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Icon(Icons.person, color: AppTheme.error, size: 20),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    tenant.tenantName,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: Theme.of(context).colorScheme.onSurface,
                    ),
                  ),
                  Text(
                    tenant.facilityName,
                    style: TextStyle(
                      fontSize: 12,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  '\$${tenant.balanceDue.toStringAsFixed(2)}',
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    color: AppTheme.error,
                  ),
                ),
                Text(
                  '${tenant.daysLate} days late',
                  style: TextStyle(
                    fontSize: 12,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildUpcomingMoveOutsCard(List<UpcomingMoveOut> moveOuts) {
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: AppTheme.warning.withOpacity(0.3), width: 1),
      ),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.move_to_inbox, color: AppTheme.warning, size: 24),
                const SizedBox(width: 8),
                Text(
                  'Upcoming Move-Outs',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w600,
                    color: Theme.of(context).colorScheme.onSurface,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            if (moveOuts.isEmpty)
              Padding(
                padding: const EdgeInsets.all(16.0),
                child: Center(
                  child: Text(
                    'No upcoming move-outs',
                    style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
                  ),
                ),
              )
            else
              ...moveOuts.take(5).map((moveOut) => _buildMoveOutItem(moveOut)),
          ],
        ),
      ),
    );
  }

  Widget _buildMoveOutItem(UpcomingMoveOut moveOut) {
    return InkWell(
      onTap: () {
        if (moveOut.contractId.isNotEmpty) {
          // Navigate to contract detail or move-out screen
          context.push('/contracts/detail?contractId=${moveOut.contractId}&facilityId=${moveOut.facilityId}');
        } else {
          // Navigate to tenant detail
          context.push('/tenants/detail?tenantId=${moveOut.tenantId}&facilityId=${moveOut.facilityId}');
        }
      },
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
        child: Row(
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: AppTheme.warning.withOpacity(0.1),
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Icon(Icons.home, color: AppTheme.warning, size: 20),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    moveOut.tenantName,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: Theme.of(context).colorScheme.onSurface,
                    ),
                  ),
                  Text(
                    '${moveOut.facilityName} - Unit ${moveOut.unitNumber}',
                    style: TextStyle(
                      fontSize: 12,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  '${moveOut.daysUntil} days',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    color: moveOut.daysUntil <= 3 ? AppTheme.error : AppTheme.warning,
                  ),
                ),
                Text(
                  _formatDate(moveOut.moveOutDate),
                  style: TextStyle(
                    fontSize: 12,
                    color: AppTheme.textSecondary,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  String _formatDate(DateTime date) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final dateOnly = DateTime(date.year, date.month, date.day);

    if (dateOnly == today) {
      return 'Today';
    } else if (dateOnly == today.add(const Duration(days: 1))) {
      return 'Tomorrow';
    } else {
      return '${date.month}/${date.day}/${date.year}';
    }
  }
}

/// Single step in the get-started checklist (dashboard empty state).
class _GetStartedStep extends StatelessWidget {
  final int number;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  const _GetStartedStep({
    required this.number,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    return Material(
      color: colorScheme.surfaceContainerHighest.withOpacity(0.5),
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Row(
            children: [
              Container(
                width: 28,
                height: 28,
                decoration: BoxDecoration(
                  color: colorScheme.primary.withOpacity(0.2),
                  shape: BoxShape.circle,
                ),
                alignment: Alignment.center,
                child: Text(
                  '$number',
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    color: colorScheme.primary,
                    fontSize: 14,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      title,
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w600,
                        color: colorScheme.onSurface,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              Icon(Icons.arrow_forward_ios, size: 14, color: colorScheme.onSurfaceVariant),
            ],
          ),
        ),
      ),
    );
  }
}

