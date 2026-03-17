import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:sfcapp/providers/feature_flag_provider.dart';
import 'package:sfcapp/router/app_route.dart';
import 'package:sfcapp/services/superadmin_service.dart';
import 'package:sfcapp/theme/app_theme.dart';
import 'package:sfcapp/screens/super_admin/tabs/accounts_tab.dart';
import 'package:sfcapp/screens/super_admin/tabs/bug_reports_tab.dart';
import 'package:sfcapp/screens/super_admin/tabs/facilities_tab.dart';
import 'package:sfcapp/screens/super_admin/tabs/feature_flags_tab.dart';
import 'package:sfcapp/screens/super_admin/tabs/metrics_tab.dart';
import 'package:sfcapp/screens/super_admin/tabs/users_tab.dart';
import 'package:sfcapp/screens/super_admin/tabs/leads_tab.dart';
import 'package:sfcapp/screens/super_admin/tabs/commission_tab.dart';

class SuperAdminScreen extends ConsumerStatefulWidget {
  const SuperAdminScreen({super.key});

  @override
  ConsumerState<SuperAdminScreen> createState() => _SuperAdminScreenState();
}

class _SuperAdminScreenState extends ConsumerState<SuperAdminScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController;

  final _tabs = const [
    _TabDef(icon: Icons.bar_chart, label: 'Metrics'),
    _TabDef(icon: Icons.business, label: 'Facilities'),
    _TabDef(icon: Icons.credit_card, label: 'Accounts'),
    _TabDef(icon: Icons.people, label: 'Users'),
    _TabDef(icon: Icons.toggle_on, label: 'Feature Flags'),
    _TabDef(icon: Icons.support_agent, label: 'Leads'),
    _TabDef(icon: Icons.request_quote, label: 'Commission'),
    _TabDef(icon: Icons.bug_report, label: 'Bug Reports'),
  ];

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 8, vsync: this);
    // Seed feature flags on first load (no-op if already seeded)
    FeatureFlagService.seedDefaults();
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  Future<void> _signOut() async {
    await FirebaseAuth.instance.signOut();
    if (mounted) context.go(AppRoute.login);
  }

  @override
  Widget build(BuildContext context) {
    final email = FirebaseAuth.instance.currentUser?.email ?? '';
    final isSuperAdmin = SuperAdminService.isEmailSuperAdmin(email);

    if (!isSuperAdmin) {
      return const Scaffold(
        body: Center(child: Text('Access denied.')),
      );
    }

    return Scaffold(
      backgroundColor: AppTheme.backgroundLight,
      appBar: AppBar(
        backgroundColor: AppTheme.backgroundDark,
        foregroundColor: Colors.white,
        elevation: 0,
        title: Row(
          children: [
            Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: AppTheme.error.withValues(alpha: 0.2),
                borderRadius: BorderRadius.circular(6),
                border: Border.all(
                    color: AppTheme.error.withValues(alpha: 0.4)),
              ),
              child: const Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.shield, size: 14, color: AppTheme.error),
                  SizedBox(width: 6),
                  Text('SUPER ADMIN',
                      style: TextStyle(
                          fontSize: 12,
                          color: AppTheme.error,
                          fontWeight: FontWeight.bold,
                          letterSpacing: 1)),
                ],
              ),
            ),
            const SizedBox(width: 16),
            Text('Platform Control',
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    color: Colors.white, fontWeight: FontWeight.w600)),
          ],
        ),
        actions: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Center(
              child: Text(email,
                  style: const TextStyle(
                      fontSize: 12, color: Colors.white70)),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.open_in_new, size: 18),
            tooltip: 'Go to Dashboard',
            onPressed: () => context.go(AppRoute.dashboard),
          ),
          IconButton(
            icon: const Icon(Icons.logout, size: 18),
            tooltip: 'Sign Out',
            onPressed: _signOut,
          ),
        ],
        bottom: TabBar(
          controller: _tabController,
          indicatorColor: AppTheme.primaryBlueLight,
          labelColor: Colors.white,
          unselectedLabelColor: Colors.white54,
          tabs: _tabs
              .map((t) => Tab(
                    icon: Icon(t.icon, size: 18),
                    text: t.label,
                  ))
              .toList(),
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: const [
          MetricsTab(),
          FacilitiesTab(),
          AccountsTab(),
          UsersTab(),
          FeatureFlagsTab(),
          LeadsTab(),
          CommissionTab(),
          BugReportsTab(),
        ],
      ),
    );
  }
}

class _TabDef {
  final IconData icon;
  final String label;
  const _TabDef({required this.icon, required this.label});
}
