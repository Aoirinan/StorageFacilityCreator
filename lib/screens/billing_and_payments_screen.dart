import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:sfcapp/providers/active_facility_provider.dart';
import 'package:sfcapp/providers/auth_provider.dart';
import 'package:sfcapp/providers/facility_provider.dart';
import 'package:sfcapp/screens/quickbooks_integration_screen.dart';
import 'package:sfcapp/screens/subscription_test_screen.dart';
import 'package:sfcapp/screens/stripe_connect_onboarding_screen.dart';
import 'package:sfcapp/theme/app_theme.dart';
import 'package:sfcapp/router/app_route.dart';

/// Combined Billing & Payments screen with Subscription and Payment Processing tabs.
/// Replaces separate Subscription and Payment Processing entries in Settings.
class BillingAndPaymentsScreen extends ConsumerStatefulWidget {
  final bool requireSubscriptionChoice;
  final String? message;
  final bool showTrialExpiredDialog;
  /// Initial tab: 0 = Subscription, 1 = Payment Processing
  final int initialTab;
  /// When provided (e.g. from route guard redirect), use this widget for Subscription tab
  final Widget? subscriptionChild;

  const BillingAndPaymentsScreen({
    super.key,
    this.requireSubscriptionChoice = false,
    this.message,
    this.showTrialExpiredDialog = false,
    this.initialTab = 0,
    this.subscriptionChild,
  });

  @override
  ConsumerState<BillingAndPaymentsScreen> createState() => _BillingAndPaymentsScreenState();
}

class _BillingAndPaymentsScreenState extends ConsumerState<BillingAndPaymentsScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(
      length: 3,
      initialIndex: widget.initialTab.clamp(0, 2),
      vsync: this,
    );
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TabBar(
          controller: _tabController,
          indicatorColor: AppTheme.primaryBlue,
          labelColor: AppTheme.primaryBlue,
          unselectedLabelColor: AppTheme.textSecondary,
          tabs: const [
            Tab(
              icon: Icon(Icons.subscriptions_outlined),
              text: 'Your Subscription',
            ),
            Tab(
              icon: Icon(Icons.account_balance_wallet_outlined),
              text: 'Payment Processing',
            ),
            Tab(
              icon: Icon(Icons.calculate_outlined),
              text: 'Accounting',
            ),
          ],
        ),
        Expanded(
          child: TabBarView(
            controller: _tabController,
            children: [
              widget.subscriptionChild ??
                  SubscriptionTestScreen(
                    requireSubscriptionChoice: widget.requireSubscriptionChoice,
                    message: widget.message,
                    showTrialExpiredDialog: widget.showTrialExpiredDialog,
                  ),
              _PaymentProcessingTab(),
              _AccountingTab(),
            ],
          ),
        ),
      ],
    );
  }
}

class _PaymentProcessingTab extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final facilitiesAsync = ref.watch(
      userFacilitiesProvider(ref.watch(authStateProvider).whenOrNull(data: (d) => d)?.uid ?? ''),
    );

    return facilitiesAsync.when(
      data: (facilities) {
        if (facilities.isEmpty) {
          return _buildNoFacilityMessage(context);
        }
        final activeFacilityId = ref.watch(activeFacilityIdProvider).whenOrNull(data: (d) => d);
        final facility = activeFacilityId != null
            ? facilities.firstWhere(
                (f) => f.id == activeFacilityId,
                orElse: () => facilities.first,
              )
            : facilities.first;
        return StripeConnectOnboardingScreen(facility: facility);
      },
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (_, __) => _buildNoFacilityMessage(context),
    );
  }

  Widget _buildNoFacilityMessage(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.account_balance_wallet_outlined,
              size: 64,
              color: AppTheme.textTertiary,
            ),
            const SizedBox(height: 24),
            Text(
              'Create a facility first',
              style: Theme.of(context).textTheme.titleLarge?.copyWith(
                color: AppTheme.textPrimary,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 12),
            Text(
              'Stripe Connect is set up per facility. Create a facility, then come back here to connect Stripe and receive tenant payments.',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: AppTheme.textSecondary,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            ElevatedButton.icon(
              onPressed: () => context.go(AppRoute.facilityCreate),
              icon: const Icon(Icons.add_business),
              label: const Text('Create Facility'),
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
}

class _AccountingTab extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final facilitiesAsync = ref.watch(
      userFacilitiesProvider(
        ref.watch(authStateProvider).whenOrNull(data: (d) => d)?.uid ?? '',
      ),
    );

    return facilitiesAsync.when(
      data: (facilities) {
        if (facilities.isEmpty) {
          return _buildNoFacilityMessage(context);
        }
        final activeFacilityId =
            ref.watch(activeFacilityIdProvider).whenOrNull(data: (d) => d);
        final facility = activeFacilityId != null
            ? facilities.firstWhere(
                (f) => f.id == activeFacilityId,
                orElse: () => facilities.first,
              )
            : facilities.first;
        return QuickBooksIntegrationScreen(facility: facility);
      },
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (_, __) => _buildNoFacilityMessage(context),
    );
  }

  Widget _buildNoFacilityMessage(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.calculate_outlined,
              size: 64,
              color: AppTheme.textTertiary,
            ),
            const SizedBox(height: 24),
            Text(
              'Create a facility first',
              style: Theme.of(context).textTheme.titleLarge?.copyWith(
                    color: AppTheme.textPrimary,
                  ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 12),
            Text(
              'QuickBooks connects per facility. Create a facility, then return to connect accounting sync.',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: AppTheme.textSecondary,
                  ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            ElevatedButton.icon(
              onPressed: () => context.go(AppRoute.facilityCreate),
              icon: const Icon(Icons.add_business),
              label: const Text('Create Facility'),
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
}
