import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:sfcapp/providers/active_facility_provider.dart';
import 'package:sfcapp/providers/auth_provider.dart';
import 'package:sfcapp/providers/facility_provider.dart';
import 'package:sfcapp/screens/quickbooks_integration_screen.dart';
import 'package:sfcapp/screens/subscription_test_screen.dart';
import 'package:sfcapp/screens/stripe_connect_onboarding_screen.dart';
import 'package:sfcapp/services/facility_service.dart';
import 'package:sfcapp/theme/app_theme.dart';
import 'package:sfcapp/utils/error_message_helper.dart';
import 'package:sfcapp/widgets/payment_processor_chooser.dart';
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

  /// True when redirected here because platform maintenance blocks users without subscription access
  final bool showMaintenanceLockoutNotice;

  const BillingAndPaymentsScreen({
    super.key,
    this.requireSubscriptionChoice = false,
    this.message,
    this.showTrialExpiredDialog = false,
    this.initialTab = 0,
    this.subscriptionChild,
    this.showMaintenanceLockoutNotice = false,
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
        if (widget.showMaintenanceLockoutNotice)
          Material(
            color: AppTheme.warning.withValues(alpha: 0.15),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.engineering_outlined,
                      color: AppTheme.warning, size: 22),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      'Platform maintenance is on. Accounts without an active trial or subscription can only use this billing page. '
                      'If you were approved for a trial, refresh the app or go to Dashboard from the sidebar. '
                      'Super admins can turn maintenance off under Super Admin → feature flags.',
                      style: TextStyle(
                        fontSize: 13,
                        height: 1.35,
                        color: Theme.of(context).colorScheme.onSurface,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
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

class _PaymentProcessingTab extends ConsumerStatefulWidget {
  @override
  ConsumerState<_PaymentProcessingTab> createState() =>
      _PaymentProcessingTabState();
}

class _PaymentProcessingTabState extends ConsumerState<_PaymentProcessingTab> {
  /// Set once the owner picks a processor in this session, so the UI advances
  /// immediately instead of waiting for the facility stream to round-trip.
  String? _justChosen;
  bool _saving = false;

  Future<void> _choose(String facilityId, String processor) async {
    setState(() => _saving = true);
    try {
      await FacilityService.updateFacility(
        facilityId: facilityId,
        paymentProcessor: processor,
      );
      if (mounted) setState(() => _justChosen = processor);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Could not save your choice: ${ErrorMessageHelper.getUserFriendlyMessage(e)}',
            ),
            backgroundColor: AppTheme.error,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
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
        final processor = _justChosen ?? facility.paymentProcessor;

        // Already on Stripe — including every facility that predates this
        // field, and any that already started Connect onboarding.
        if (processor == PaymentProcessor.stripe ||
            facility.stripeConnectAccountId != null) {
          return StripeConnectOnboardingScreen(facility: facility);
        }

        if (processor == PaymentProcessor.square) {
          return _buildSquareComingSoon(context);
        }

        return _buildProcessorChoice(context, facility.id);
      },
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (_, __) => _buildNoFacilityMessage(context),
    );
  }

  Widget _buildProcessorChoice(BuildContext context, String facilityId) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'How do you want to get paid?',
            style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
          ),
          const SizedBox(height: 8),
          Text(
            'Choose who processes your tenants\' card payments. You can change '
            'this later, as long as you haven\'t connected an account yet.',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: AppTheme.textSecondary,
                ),
          ),
          const SizedBox(height: 24),
          if (_saving)
            const Center(child: CircularProgressIndicator())
          else
            PaymentProcessorChooser(
              selected: null,
              allowDefer: false,
              onChanged: (value) {
                if (value != null) _choose(facilityId, value);
              },
            ),
        ],
      ),
    );
  }

  Widget _buildSquareComingSoon(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.hourglass_empty, size: 64, color: AppTheme.textTertiary),
            const SizedBox(height: 24),
            Text(
              'Square support is on the way',
              style: Theme.of(context).textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
            ),
            const SizedBox(height: 12),
            Text(
              'You\'ve marked this facility as using Square. Connecting your '
              'Square account isn\'t available yet — we\'ll let you know as '
              'soon as it is.',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: AppTheme.textSecondary,
                  ),
            ),
          ],
        ),
      ),
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
