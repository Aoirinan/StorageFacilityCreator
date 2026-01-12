import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:go_router/go_router.dart';
import '../providers/auth_provider.dart';
import '../services/debug_logger.dart';
import '../providers/facility_provider.dart';
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
import 'auth/login_screen.dart';
import 'client_detail_screen.dart';
import 'facility_creation_wizard.dart';
import 'facility_management_screen.dart';
import 'client_list_screen.dart';
import 'facility_map_editor_screen.dart';
import 'payment_list_screen.dart';
import 'reminder_list_screen.dart';
import 'messaging_screen.dart';
import 'late_dashboard_screen.dart';
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
          SnackBar(content: Text('Error: $e')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final isMobile = MediaQuery.of(context).size.width < 900;
    final searchState = ref.watch(search.searchStateProvider(widget.user.uid));

    return Scaffold(
      body: Row(
        children: [
          // Sidebar
          if (!isMobile)
            ModernSidebar(
              currentRoute: _currentRoute,
              isCollapsed: _sidebarCollapsed,
              onNavigate: _handleNavigation,
            ),
          
          // Main content
          Expanded(
            child: Column(
              children: [
                // Top bar
                _buildTopBar(context, isMobile),
                
                // Main content area
                Expanded(
                  child: _showSearchResults
                      ? _buildSearchResults(searchState)
                      : _buildDashboard(),
                ),
              ],
            ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _handleNewFacilityPressed(context),
        backgroundColor: AppTheme.primaryBlue,
        foregroundColor: AppTheme.textOnDark,
        tooltip: 'Create facility',
        icon: const Icon(Icons.add),
        label: const Text('New Facility'),
      ),
      drawer: isMobile ? Drawer(
        child: ModernSidebar(
          currentRoute: _currentRoute,
          isCollapsed: false,
          onNavigate: (route) {
            Navigator.of(context).pop();
            _handleNavigation(route);
          },
        ),
      ) : null,
    );
  }

  Widget _buildTopBar(BuildContext context, bool isMobile) {
    return Container(
      height: 64,
      decoration: BoxDecoration(
        color: AppTheme.textOnDark,
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
                tooltip: 'Open navigation menu',
                onPressed: () => Scaffold.of(context).openDrawer(),
              ),
            ),
          const Text(
            'SFC',
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.w700,
              color: AppTheme.primaryBlue,
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
                    borderSide: BorderSide(color: AppTheme.borderLight),
                  ),
                  filled: true,
                  fillColor: AppTheme.backgroundLight,
                  contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                ),
              ),
            ),
          ),
          
          const Spacer(),
          
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
    final isMobile = MediaQuery.of(context).size.width < 900;

    return SingleChildScrollView(
      padding: EdgeInsets.all(isMobile ? 16 : 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Welcome section
          _buildWelcomeSection(),
          const SizedBox(height: 24),
          
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
    
    return facilitiesAsync.when(
      data: (facilities) {
        final facilityName = facilities.isNotEmpty ? facilities.first.name : 'Your Facility';
        return Card(
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: BorderSide(color: AppTheme.borderLight, width: 1),
          ),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Row(
              children: [
                Container(
                  width: 56,
                  height: 56,
                  decoration: BoxDecoration(
                    color: AppTheme.primaryBlue.withOpacity(0.1),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: const Icon(
                    Icons.dashboard,
                    color: AppTheme.primaryBlue,
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
                          color: AppTheme.textSecondary,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        facilityName,
                        style: const TextStyle(
                          fontSize: 24,
                          fontWeight: FontWeight.w700,
                          color: AppTheme.textPrimary,
                          letterSpacing: -0.5,
                        ),
                      ),
                      if (widget.user.email != null) ...[
                        const SizedBox(height: 4),
                        Text(
                          widget.user.email!,
                          style: TextStyle(
                            fontSize: 14,
                            color: AppTheme.textSecondary,
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

  Widget _buildMetricsGrid(DashboardStats stats) {
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

        return GridView.count(
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
              subtitle: '${stats.occupiedUnits} occupied, ${stats.availableUnits} available',
              icon: Icons.home_work,
              color: AppTheme.info,
            ),
            MetricCard(
              title: 'Monthly Revenue',
              value: '\$${stats.monthlyRevenue.toStringAsFixed(0)}',
              subtitle: 'Recurring revenue',
              icon: Icons.attach_money,
              color: AppTheme.success,
            ),
            MetricCard(
              title: 'Past Due',
              value: stats.pastDueCount.toString(),
              subtitle: 'Overdue payments',
              icon: Icons.warning,
              color: stats.pastDueCount > 0 ? AppTheme.error : AppTheme.success,
              onTap: stats.pastDueCount > 0
                  ? () => ModernNavigationService.navigateToRoute(context, '/delinquency')
                  : null,
            ),
          ],
        );
      },
    );
  }

  Widget _buildChartsSection(DashboardStats stats) {
    final isMobile = MediaQuery.of(context).size.width < 900;
    
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth < 900) {
          // Stack vertically on mobile
          return Column(
            children: [
              _buildOccupancyCard(stats),
              const SizedBox(height: 16),
              activity.ActivityFeed(
                activities: _generateSampleActivities(stats),
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
              activities: _generateSampleActivities(stats),
            ),
          ),
          ],
        );
      },
    );
  }

  Widget _buildOccupancyCard(DashboardStats stats) {
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: AppTheme.borderLight, width: 1),
      ),
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'OCCUPANCY RATE',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: AppTheme.textSecondary,
                letterSpacing: 0.5,
              ),
            ),
            const SizedBox(height: 20),
            Center(
              child: DonutChart(
                value: stats.occupancyRate,
                label: 'Occupied',
                color: AppTheme.primaryBlue,
                size: 160,
              ),
            ),
            const SizedBox(height: 16),
            Center(
              child: Text(
                '${(stats.occupancyRate * 100).toStringAsFixed(1)}%',
                style: const TextStyle(
                  fontSize: 32,
                  fontWeight: FontWeight.w700,
                  color: AppTheme.textPrimary,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  List<activity.ActivityItem> _generateSampleActivities(DashboardStats stats) {
    final activities = <activity.ActivityItem>[];
    
    if (stats.totalTenants > 0) {
      activities.add(activity.ActivityItem(
        title: 'Tenants',
        subtitle: '${stats.totalTenants} total tenants across all facilities',
        icon: Icons.people,
        iconColor: AppTheme.primaryBlue,
        timestamp: DateTime.now().subtract(const Duration(minutes: 5)),
      ));
    }
    
    if (stats.totalUnits > 0) {
      activities.add(activity.ActivityItem(
        title: 'Units',
        subtitle: '${stats.occupiedUnits} occupied, ${stats.availableUnits} available',
        icon: Icons.home_work,
        iconColor: AppTheme.info,
        timestamp: DateTime.now().subtract(const Duration(minutes: 10)),
      ));
    }
    
    if (stats.monthlyRevenue > 0) {
      activities.add(activity.ActivityItem(
        title: 'Monthly Revenue',
        subtitle: '\$${stats.monthlyRevenue.toStringAsFixed(0)} recurring revenue',
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
        const Text(
          'Quick Actions',
          style: TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.w600,
            color: AppTheme.textPrimary,
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
              ],
            );
          },
        ),
      ],
    );
  }

  Widget _buildQuickActionCard(String label, IconData icon, Color color, VoidCallback onTap) {
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: AppTheme.borderLight, width: 1),
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
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: AppTheme.textPrimary,
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
          return Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.search_off, size: 64, color: AppTheme.textSecondary),
                const SizedBox(height: 16),
                Text(
                  'No results found',
                  style: TextStyle(
                    fontSize: 18,
                    color: AppTheme.textSecondary,
                  ),
                ),
              ],
            ),
          );
        }

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
                  color: AppTheme.primaryBlue,
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
      loading: () => Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const CircularProgressIndicator(),
            const SizedBox(height: 16),
            Text(
              'Searching...',
              style: TextStyle(
                color: AppTheme.textSecondary,
                fontSize: 14,
              ),
            ),
          ],
        ),
      ),
      error: (error, stack) => Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.error_outline, size: 64, color: AppTheme.error),
            const SizedBox(height: 16),
            Text(
              'Error searching',
              style: TextStyle(
                fontSize: 18,
                color: AppTheme.textPrimary,
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
                  color: AppTheme.textSecondary,
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
                backgroundColor: AppTheme.primaryBlue,
                foregroundColor: AppTheme.textOnDark,
              ),
            ),
          ],
        ),
      ),
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
            const SnackBar(
              content: Text('Unable to locate tenant - facility ID missing'),
              backgroundColor: Colors.red,
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
          SnackBar(content: Text('Error: $e')),
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
          SnackBar(content: Text('Error: $e')),
        );
      }
    }
  }

  Widget _buildErrorWidget(Object error) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Center(
          child: Column(
            children: [
              const Icon(Icons.error_outline, size: 48, color: AppTheme.error),
              const SizedBox(height: 16),
              Text(
                'Error loading dashboard',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: AppTheme.textPrimary,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                ErrorMessageHelper.getUserFriendlyMessage(error),
                style: TextStyle(
                  fontSize: 14,
                  color: AppTheme.textSecondary,
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
              backgroundColor: AppTheme.error,
              foregroundColor: AppTheme.textOnDark,
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
                const Text(
                  'Top Delinquent Tenants',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w600,
                    color: AppTheme.textPrimary,
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
              const Padding(
                padding: EdgeInsets.all(16.0),
                child: Center(
                  child: Text(
                    'No delinquent tenants',
                    style: TextStyle(color: AppTheme.textSecondary),
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
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: AppTheme.textPrimary,
                    ),
                  ),
                  Text(
                    tenant.facilityName,
                    style: TextStyle(
                      fontSize: 12,
                      color: AppTheme.textSecondary,
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
                const Text(
                  'Upcoming Move-Outs',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w600,
                    color: AppTheme.textPrimary,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            if (moveOuts.isEmpty)
              const Padding(
                padding: EdgeInsets.all(16.0),
                child: Center(
                  child: Text(
                    'No upcoming move-outs',
                    style: TextStyle(color: AppTheme.textSecondary),
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
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: AppTheme.textPrimary,
                    ),
                  ),
                  Text(
                    '${moveOut.facilityName} - Unit ${moveOut.unitNumber}',
                    style: TextStyle(
                      fontSize: 12,
                      color: AppTheme.textSecondary,
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

