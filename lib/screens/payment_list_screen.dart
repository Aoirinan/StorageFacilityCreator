import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show debugPrint, kDebugMode, kIsWeb;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import '../models/payment_model.dart';
import '../models/autopay_event_model.dart';
import '../models/stripe_connect_status_model.dart';
import '../providers/payment_provider.dart';
import '../providers/auth_provider.dart';
import '../providers/facility_provider.dart';
import '../providers/active_facility_provider.dart';
import '../models/facility_model.dart';
import '../services/facility_creator_account_service.dart';
import '../services/autopay_service.dart';
import '../services/stripe_connect_service.dart';
import '../widgets/modern_page_wrapper.dart';
import '../theme/app_theme.dart';
import '../constants/app_constants.dart';
import '../router/app_router.dart';
import '../router/app_route.dart';
import '../utils/breakpoints.dart';
import '../utils/error_message_helper.dart';
import '../utils/setup_retry_controller.dart';
import 'payment_detail_screen.dart';
import 'payment_creation_screen.dart';
import 'facility_creation_wizard.dart';
import 'facility_map_editor_screen.dart';
import '../providers/tenant_provider.dart';
import '../services/tenant_service.dart';
import '../models/tenant_model.dart';
import '../models/tenant_autopay_model.dart';
import '../services/statement_service.dart';
import '../services/facility_service.dart';
import 'ledger_screen.dart';
import '../ui/payments/stripe_embedded_payment_dialog.dart';
import '../services/stripe_service.dart';
import '../utils/stripe_redirect_params.dart';
import '../ui/payments/tenant_billing_panel.dart';

class PaymentListScreen extends ConsumerStatefulWidget {
  const PaymentListScreen({super.key});

  @override
  ConsumerState<PaymentListScreen> createState() => _PaymentListScreenState();
}

class _PaymentListScreenState extends ConsumerState<PaymentListScreen> {
  String _selectedFacilityId = '';
  String _searchQuery = '';
  PaymentStatus? _statusFilter;
  PaymentMethod? _methodFilter;
  String? _selectedTenantIdFilter; // null = All tenants
  DateTime? _filterDateStart;
  DateTime? _filterDateEnd;
  String _autopayTenantSearch = '';
  bool _autopayToggleLoading = false;
  bool _autopayChargeDaySaving = false;
  bool _appliedRouteParams = false;
  final SetupRetryController _setupRetry = SetupRetryController();

  @override
  void initState() {
    super.initState();
    _loadUserFacilities();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_appliedRouteParams) return;
    final uri = GoRouterState.of(context).uri;
    final params = uri.queryParameters;
    final tab = params['tab'];
    final tenantId = params['tenantId'];
    final cardAdded = params['cardAdded'] == '1' || params['cardAdded'] == 'true';
    final facilityId = params['facilityId'];
    if (tab == 'autopay' || tab == 'onetime' || tenantId != null || cardAdded) {
      _appliedRouteParams = true;
      if (tab == 'autopay') {
        ref.read(paymentsTabIndexProvider.notifier).state = 1;
        if (tenantId != null && tenantId.isNotEmpty) {
          ref.read(paymentsAutopaySelectedTenantIdProvider.notifier).state = tenantId;
        }
      }
      if (tab == 'onetime') {
        ref.read(paymentsTabIndexProvider.notifier).state = 2;
        if (tenantId != null && tenantId.isNotEmpty) {
          ref.read(paymentsAutopaySelectedTenantIdProvider.notifier).state = tenantId;
        }
      }
      if (facilityId != null && facilityId.isNotEmpty) {
        setState(() => _selectedFacilityId = facilityId);
      }
      if (cardAdded && tenantId != null && facilityId != null && facilityId!.isNotEmpty && mounted) {
        WidgetsBinding.instance.addPostFrameCallback((_) => _handleCardAddedReturn(tenantId!, facilityId!));
      }
    }
  }

  /// Handles return from add-card flow. If Stripe redirected (Link/3DS), attach the
  /// payment method now; otherwise the in-page flow already attached it.
  Future<void> _handleCardAddedReturn(String tenantId, String facilityId) async {
    if (!mounted) return;
    if (kIsWeb) {
      final redirectParams = getStripeRedirectParams();
      final setupIntentId = redirectParams['setup_intent'];
      if (setupIntentId != null && setupIntentId.isNotEmpty) {
        try {
          await StripeService.attachTenantPaymentMethodFromRedirect(
            facilityId: facilityId,
            tenantId: tenantId,
            setupIntentId: setupIntentId,
          );
          clearStripeRedirectParamsFromUrl();
          if (mounted) ref.invalidate(facilityTenantsProvider(facilityId));
        } catch (e) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(
                  'Card was saved in Stripe but could not link to this tenant. ${ErrorMessageHelper.getUserFriendlyMessage(e)}',
                ),
                backgroundColor: AppTheme.error,
                duration: const Duration(seconds: 5),
              ),
            );
          }
          return;
        }
      }
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: const Text('Card added successfully.'),
        backgroundColor: AppTheme.success,
        duration: const Duration(seconds: 4),
        action: SnackBarAction(
          label: 'Turn on Autopay?',
          onPressed: () {
            ref.read(paymentsAutopaySelectedTenantIdProvider.notifier).state = tenantId;
            ref.read(paymentsTabIndexProvider.notifier).state = 1;
          },
        ),
      ),
    );
  }

  Future<void> _loadUserFacilities() async {
    try {
      final authState = ref.read(authStateProvider);
      if (authState.hasValue && authState.value != null) {
        final user = authState.value!;
        
        // CRITICAL: Ensure account exists BEFORE trying to load facilities
        // Permission errors often occur because account doesn't exist yet
        try {
          await FacilityCreatorAccountService.getOrCreateAccountForCurrentUser();
          if (kDebugMode) {
            debugPrint('✅ Account verified/created for user: ${user.uid}');
          }
        } catch (accountError) {
          // Account creation failed - show helpful error
          if (mounted) {
            debugPrint('❌ Could not ensure account exists: $accountError');
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text('Account setup error: $accountError. Please try again or contact support.'),
                backgroundColor: AppTheme.warning,
                duration: const Duration(seconds: 5),
                action: SnackBarAction(
                  label: 'Retry',
                  onPressed: () => _loadUserFacilities(),
                ),
              ),
            );
            return; // Don't try to load facilities if account creation failed
          }
        }

        ref.invalidate(userFacilitiesProvider(user.uid));
        // Prefer active facility so Payments and Stripe Connect page stay in sync.
        final facilitiesAsync = await ref.read(userFacilitiesProvider(user.uid).future);
        final facilities = facilitiesAsync as List<FacilityModel>? ?? <FacilityModel>[];
        _setupRetry.reset();
        if (facilities.isNotEmpty) {
          final activeId = ref.read(activeFacilityIdProvider).whenOrNull(data: (d) => d);
          final initialId = (activeId != null && facilities.any((f) => f.id == activeId))
              ? activeId
              : facilities.first.id;
          setState(() {
            _selectedFacilityId = initialId;
          });
        } else {
          if (kDebugMode) {
            debugPrint('ℹ️ No facilities found for user: ${user.uid}');
          }
        }
      }
    } catch (e) {
      if (mounted) {
        debugPrint('❌ Error loading facilities in payment screen: $e');
        final errorMessage = e.toString();
        final isPermissionError = errorMessage.contains('permission-denied') || 
                                  errorMessage.contains('Missing or insufficient permissions');
        if (isPermissionError && _setupRetry.canRetry) {
          _setupRetry.schedule(
            onRetry: () {
              if (!mounted) return;
              _loadUserFacilities();
            },
          );
          return;
        }

        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              isPermissionError
                  ? 'Permission error: Your account may need setup. Please check your account status or contact support.'
                  : 'Error loading facilities: $errorMessage',
            ),
            backgroundColor: AppTheme.error,
            duration: const Duration(seconds: 6),
            action: SnackBarAction(
              label: 'Retry',
              onPressed: () => _loadUserFacilities(),
            ),
          ),
        );
      }
    }
  }

  @override
  void dispose() {
    _setupRetry.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Use AsyncValue to properly handle loading state
    final authState = ref.watch(authStateProvider);

    ref.listen<AsyncValue<String?>>(activeFacilityIdProvider, (prev, next) {
      if (!mounted) return;
      final user = ref.read(authStateProvider).maybeWhen(
            data: (u) => u,
            orElse: () => null,
          );
      if (user == null) return;
      final facilities = ref.read(userFacilitiesProvider(user.uid)).maybeWhen(
            data: (f) => f,
            orElse: () => null,
          );
      if (facilities == null || facilities.isEmpty) return;
      final nextId = next.whenOrNull(data: (d) => d);
      if (nextId != null &&
          facilities.any((f) => f.id == nextId) &&
          _selectedFacilityId != nextId) {
        setState(() => _selectedFacilityId = nextId);
      }
    });

    return authState.when(
      data: (user) {
        if (user == null) {
          return const Center(child: Text('Not authenticated'));
        }
        
        final facilitiesAsync = ref.watch(userFacilitiesProvider(user.uid));
        
        return facilitiesAsync.when(
          data: (facilities) {
            // Only show "no facilities" if loading is complete AND facilities are empty
            if (facilities.isEmpty) {
              return _buildNoFacilitiesMessage();
            }
            
            // Auto-select facility if not selected: prefer active facility so Stripe status matches
            if (_selectedFacilityId.isEmpty && facilities.isNotEmpty) {
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (mounted) {
                  final activeId = ref.read(activeFacilityIdProvider).whenOrNull(data: (d) => d);
                  final initialId = (activeId != null && facilities.any((f) => f.id == activeId))
                      ? activeId
                      : facilities.first.id;
                  setState(() => _selectedFacilityId = initialId);
                }
              });
              return const Center(child: CircularProgressIndicator());
            }
            
            final tabIndex = ref.watch(paymentsTabIndexProvider);
            return Column(
              children: [
                Container(
                  color: AppTheme.surface,
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  child: Row(
                    children: [
                      _TabButton(
                        label: 'Transactions',
                        selected: tabIndex == 0,
                        onTap: () => ref.read(paymentsTabIndexProvider.notifier).state = 0,
                      ),
                      const SizedBox(width: 8),
                      _TabButton(
                        label: 'Autopay',
                        selected: tabIndex == 1,
                        onTap: () => ref.read(paymentsTabIndexProvider.notifier).state = 1,
                      ),
                      const SizedBox(width: 8),
                      _TabButton(
                        label: 'Take payment',
                        selected: tabIndex == 2,
                        onTap: () => ref.read(paymentsTabIndexProvider.notifier).state = 2,
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: tabIndex == 1
                      ? _buildAutopayTab()
                      : tabIndex == 2
                          ? _buildOneTimePaymentTab()
                          : _buildTransactionsTab(),
                ),
              ],
            );
          },
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (error, stack) => Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.error_outline, size: 64, color: AppTheme.error),
                const SizedBox(height: 16),
                Text(
                  'Error loading facilities',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 8),
                Text(
                  error.toString(),
                  style: Theme.of(context).textTheme.bodySmall,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 16),
                ElevatedButton(
                  onPressed: () {
                    ref.invalidate(userFacilitiesProvider(user.uid));
                    _loadUserFacilities();
                  },
                  child: const Text('Retry'),
                ),
              ],
            ),
          ),
        );
      },
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (error, stack) => Center(
        child: Text('Error: $error'),
      ),
    );
  }
  
  Widget _buildTransactionsTab() {
    return Column(
      children: [
        _buildFilters(),
        _buildStats(),
        Expanded(child: _buildPaymentsList()),
      ],
    );
  }

  Widget _buildAutopayTab() {
    if (_selectedFacilityId.isEmpty) return _buildNoFacilitiesMessage();
    final selectedTenantId = ref.watch(paymentsAutopaySelectedTenantIdProvider);
    final isPhone = MediaQuery.of(context).size.width < Breakpoints.xs;

    if (isPhone) {
      // Mobile: stack list then detail, show one at a time
      final hasSelection = selectedTenantId != null;
      return Column(
        children: [
          if (hasSelection) _buildAutopayMobileBackBar(),
          Expanded(
            child: hasSelection
                ? _buildAutopayDetailPanel(selectedTenantId!)
                : _buildAutopayTenantList(selectedTenantId, true),
          ),
        ],
      );
    }

    // Desktop: side-by-side
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          width: 280,
          child: _buildAutopayTenantList(selectedTenantId, false),
        ),
        Expanded(
          flex: 2,
          child: selectedTenantId == null
              ? Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.person_search, size: 64, color: AppTheme.textTertiary),
                      const SizedBox(height: 16),
                      Text('Select a tenant', style: Theme.of(context).textTheme.titleMedium),
                    ],
                  ),
                )
              : _buildAutopayDetailPanel(selectedTenantId),
        ),
      ],
    );
  }

  Widget _buildOneTimePaymentTab() {
    if (_selectedFacilityId.isEmpty) return _buildNoFacilitiesMessage();
    final selectedTenantId = ref.watch(paymentsAutopaySelectedTenantIdProvider);
    final isPhone = MediaQuery.of(context).size.width < Breakpoints.xs;

    if (isPhone) {
      final hasSelection = selectedTenantId != null;
      return Column(
        children: [
          if (hasSelection) _buildAutopayMobileBackBar(),
          Expanded(
            child: hasSelection
                ? _buildOneTimePaymentDetailPanel(selectedTenantId!)
                : _buildAutopayTenantList(selectedTenantId, true),
          ),
        ],
      );
    }

    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          width: 280,
          child: _buildAutopayTenantList(selectedTenantId, false),
        ),
        Expanded(
          flex: 2,
          child: selectedTenantId == null
              ? Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.payment, size: 64, color: AppTheme.textTertiary),
                      const SizedBox(height: 16),
                      Text('Select a tenant to take a payment', style: Theme.of(context).textTheme.titleMedium),
                    ],
                  ),
                )
              : _buildOneTimePaymentDetailPanel(selectedTenantId!),
        ),
      ],
    );
  }

  Widget _buildOneTimePaymentDetailPanel(String tenantId) {
    return Consumer(
      builder: (context, ref, _) {
        final tenantsAsync = ref.watch(facilityTenantsProvider(_selectedFacilityId));
        return tenantsAsync.when(
          data: (tenants) {
            TenantModel? tenant;
            for (final t in tenants) {
              if (t.id == tenantId) {
                tenant = t;
                break;
              }
            }
            if (tenant == null) {
              return const Center(child: Text('Tenant not found'));
            }
            return SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: TenantBillingPanel(
                facilityId: _selectedFacilityId,
                tenantId: tenant!.id,
                tenantName: tenant.name,
                defaultPaymentMethodId: tenant.stripe.defaultPaymentMethodId,
              ),
            );
          },
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) => Center(child: Text(ErrorMessageHelper.getUserFriendlyMessage(e))),
        );
      },
    );
  }

  Widget _buildAutopayMobileBackBar() {
    final cs = Theme.of(context).colorScheme;
    return Material(
      color: cs.surfaceContainerHighest,
      child: InkWell(
        onTap: () => ref.read(paymentsAutopaySelectedTenantIdProvider.notifier).state = null,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(
            children: [
              Icon(Icons.arrow_back, color: cs.primary, size: 20),
              const SizedBox(width: 8),
              Text(
                'Back to list',
                style: Theme.of(context).textTheme.titleSmall?.copyWith(
                  color: cs.primary,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildAutopayTenantList(String? selectedTenantId, bool isPhone) {
    final theme = Theme.of(context);
    final isCompact = isPhone;
    return Card(
      margin: const EdgeInsets.all(8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: EdgeInsets.all(isCompact ? 6 : 8),
            child: Text(
              'Tenants',
              style: theme.textTheme.titleSmall?.copyWith(
                fontSize: isCompact ? 12 : null,
              ),
            ),
          ),
          Padding(
            padding: EdgeInsets.symmetric(horizontal: isCompact ? 6 : 8),
            child: TextField(
              decoration: InputDecoration(
                hintText: 'Search tenant...',
                prefixIcon: Icon(Icons.search, size: isCompact ? 18 : 20),
                isDense: true,
                border: const OutlineInputBorder(),
                contentPadding: EdgeInsets.symmetric(
                  horizontal: isCompact ? 8 : 12,
                  vertical: isCompact ? 8 : 10,
                ),
              ),
              onChanged: (v) => setState(() => _autopayTenantSearch = v.trim().toLowerCase()),
            ),
          ),
          SizedBox(height: isCompact ? 6 : 8),
          Expanded(
            child: Consumer(
              builder: (context, ref, _) {
                final tenantsAsync = ref.watch(facilityTenantsProvider(_selectedFacilityId));
                return tenantsAsync.when(
                  data: (tenants) {
                    var list = tenants;
                    if (_autopayTenantSearch.isNotEmpty) {
                      list = tenants.where((t) =>
                        t.name.toLowerCase().contains(_autopayTenantSearch) ||
                        (t.unitNumber.toLowerCase().contains(_autopayTenantSearch)) ||
                        (t.email.toLowerCase().contains(_autopayTenantSearch))).toList();
                    }
                    if (list.isEmpty) {
                      return const Center(child: Text('No tenants'));
                    }
                    return ListView.builder(
                      itemCount: list.length,
                      padding: EdgeInsets.zero,
                      itemBuilder: (context, i) {
                        final t = list[i];
                        final selected = t.id == selectedTenantId;
                        return ListTile(
                          dense: isCompact,
                          selected: selected,
                          title: Text(
                            t.name,
                            style: TextStyle(
                              fontSize: isCompact ? 13 : null,
                              fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                          subtitle: t.unitNumber.isNotEmpty
                              ? Text(
                                  'Unit ${t.unitNumber}',
                                  style: TextStyle(fontSize: isCompact ? 11 : null),
                                  overflow: TextOverflow.ellipsis,
                                )
                              : null,
                          onTap: () => ref.read(paymentsAutopaySelectedTenantIdProvider.notifier).state = t.id,
                        );
                      },
                    );
                  },
                  loading: () => const Center(child: CircularProgressIndicator()),
                  error: (e, _) => Center(child: Text(ErrorMessageHelper.getUserFriendlyMessage(e))),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAutopayDetailPanel(String tenantId) {
    return Consumer(
      builder: (context, ref, _) {
        final tenantsAsync = ref.watch(facilityTenantsProvider(_selectedFacilityId));
        final statusAsync = ref.watch(stripeConnectStatusProvider(_selectedFacilityId));
        return tenantsAsync.when(
          data: (tenants) {
            TenantModel? tenant;
            for (final t in tenants) {
              if (t.id == tenantId) { tenant = t; break; }
            }
            if (tenant == null) {
              return const Center(child: Text('Tenant not found'));
            }
            // Single source of truth: stripeConnectGetStatus. Only treat as connected when we have a successful result with isEnabled.
            final stripeConnected = statusAsync.whenOrNull(data: (d) => d)?.isEnabled ?? false;
            // When status failed to load, show error + Retry so we don't wrongly show "not connected"
            if (statusAsync.hasError) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _autopayDetailContent(tenant!, false),
                  const SizedBox(height: 16),
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        children: [
                          Icon(Icons.warning_amber, size: 40, color: AppTheme.warning),
                          const SizedBox(height: 8),
                          Text('Could not load Stripe status', style: Theme.of(context).textTheme.titleSmall),
                          const SizedBox(height: 4),
                          Text(ErrorMessageHelper.getUserFriendlyMessage(statusAsync.error!), style: Theme.of(context).textTheme.bodySmall, textAlign: TextAlign.center),
                          const SizedBox(height: 12),
                          ElevatedButton.icon(
                            onPressed: () => ref.invalidate(stripeConnectStatusProvider(_selectedFacilityId)),
                            icon: const Icon(Icons.refresh, size: 18),
                            label: const Text('Refresh status'),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              );
            }
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (statusAsync.isLoading)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Row(
                      children: [
                        SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
                        const SizedBox(width: 8),
                        Text('Checking Stripe…', style: Theme.of(context).textTheme.bodySmall),
                      ],
                    ),
                  ),
                _autopayDetailContent(tenant!, stripeConnected),
              ],
            );
          },
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) => Center(child: Text(ErrorMessageHelper.getUserFriendlyMessage(e))),
        );
      },
    );
  }

  Widget _autopayDetailContent(TenantModel tenant, bool stripeConnected) {
    final autopayOn = tenant.autopay.isOn;
    final hasCard = tenant.stripe.hasPaymentMethod;
    final summary = tenant.stripe.paymentMethodSummary?.displayLabel ?? '—';
    final lastUpdated = tenant.autopay.updatedAt;
    final lastUpdatedBy = tenant.autopay.updatedBy.value;
    final isPhone = MediaQuery.of(context).size.width < Breakpoints.xs;
    final pad = isPhone ? 12.0 : 16.0;
    final bodySize = isPhone ? 13.0 : null;
    final smallSize = isPhone ? 11.0 : null;
    return SingleChildScrollView(
      padding: EdgeInsets.all(pad),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            tenant.name,
            style: Theme.of(context).textTheme.titleLarge?.copyWith(
              fontSize: isPhone ? 18 : null,
            ),
            overflow: TextOverflow.ellipsis,
          ),
          if (tenant.unitNumber.isNotEmpty)
            Text(
              'Unit ${tenant.unitNumber}',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                fontSize: bodySize,
              ),
            ),
          SizedBox(height: isPhone ? 12 : 16),
          if (!stripeConnected)
            Container(
              padding: EdgeInsets.all(isPhone ? 10 : 12),
              decoration: BoxDecoration(
                color: AppTheme.warning.withOpacity(0.15),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: AppTheme.warning),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.warning_amber, color: AppTheme.warning, size: isPhone ? 20 : 24),
                  SizedBox(width: isPhone ? 8 : 8),
                  Expanded(
                    child: Text(
                      "This facility's Stripe is not connected. Connect Stripe in facility settings to manage payments and autopay.",
                      style: TextStyle(color: AppTheme.warning, fontSize: bodySize),
                    ),
                  ),
                ],
              ),
            ),
          if (!stripeConnected) SizedBox(height: isPhone ? 12 : 16),
          Card(
            child: Padding(
              padding: EdgeInsets.all(pad),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Autopay status',
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(fontSize: isPhone ? 12 : null),
                  ),
                  SizedBox(height: isPhone ? 6 : 8),
                  Row(
                    children: [
                      Text(
                        autopayOn ? 'ON' : 'OFF',
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: bodySize,
                          color: autopayOn ? AppTheme.success : AppTheme.textSecondary,
                        ),
                      ),
                      SizedBox(width: isPhone ? 12 : 16),
                      if (stripeConnected)
                        Switch(
                          value: autopayOn,
                          onChanged: hasCard || !autopayOn
                              ? (v) => _showAutopayConfirm(context, tenant, v)
                              : null,
                        ),
                    ],
                  ),
                  SizedBox(height: isPhone ? 8 : 12),
                  Text(
                    'Payment method on file: ${hasCard ? "Yes" : "No"}',
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(fontSize: bodySize),
                  ),
                  if (hasCard)
                    Text(
                      'Default: $summary',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(fontSize: smallSize),
                      overflow: TextOverflow.ellipsis,
                    ),
                  SizedBox(height: isPhone ? 10 : 12),
                  Text(
                    'Autopay charge date',
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(fontSize: isPhone ? 12 : null),
                  ),
                  SizedBox(height: isPhone ? 4 : 6),
                  Text(
                    'Day of the month to charge rent on autopay. For months with fewer days, the last day of that month is used.',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          fontSize: smallSize,
                          color: AppTheme.textSecondary,
                        ),
                  ),
                  SizedBox(height: isPhone ? 6 : 8),
                  if (_autopayChargeDaySaving)
                    const Padding(
                      padding: EdgeInsets.only(bottom: 8),
                      child: LinearProgressIndicator(minHeight: 2),
                    ),
                  DropdownButtonFormField<int?>(
                    value: () {
                      final d = tenant.autopay.chargeDayOfMonth;
                      if (d == null || d < 1 || d > 31) return null;
                      return d;
                    }(),
                    decoration: InputDecoration(
                      labelText: 'Day of month',
                      border: const OutlineInputBorder(),
                      isDense: true,
                      contentPadding: EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: isPhone ? 8 : 10,
                      ),
                    ),
                    items: [
                      const DropdownMenuItem<int?>(
                        value: null,
                        child: Text('Not set (default)'),
                      ),
                      ...List.generate(
                        31,
                        (i) => DropdownMenuItem<int?>(
                          value: i + 1,
                          child: Text('${i + 1}'),
                        ),
                      ),
                    ],
                    onChanged: _autopayChargeDaySaving
                        ? null
                        : (v) => _onAutopayChargeDayChanged(tenant, v),
                  ),
                  if (lastUpdated != null) ...[
                    SizedBox(height: isPhone ? 6 : 8),
                    Text(
                      'Last change: $lastUpdatedBy · ${DateFormat.yMMMd().add_Hm().format(lastUpdated)}',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(fontSize: smallSize),
                    ),
                  ],
                  if (!hasCard && !autopayOn && stripeConnected) ...[
                    SizedBox(height: isPhone ? 10 : 12),
                    OutlinedButton.icon(
                      icon: Icon(Icons.credit_card, size: isPhone ? 16 : 20),
                      label: Text(
                        'Open tenant to add card',
                        style: TextStyle(fontSize: isPhone ? 12 : null),
                      ),
                      onPressed: () => context.push(AppRoute.tenantDetail, extra: tenant),
                    ),
                  ],
                ],
              ),
            ),
          ),
          SizedBox(height: isPhone ? 16 : 24),
          Text(
            'Autopay Activity',
            style: Theme.of(context).textTheme.titleMedium?.copyWith(fontSize: isPhone ? 15 : null),
          ),
          SizedBox(height: isPhone ? 6 : 8),
          _buildAutopayActivitySection(),
        ],
      ),
    );
  }

  Future<void> _onAutopayChargeDayChanged(TenantModel tenant, int? day) async {
    final current = tenant.autopay.chargeDayOfMonth;
    final a = current == null || current < 1 || current > 31 ? null : current;
    if (day == a) return;

    setState(() => _autopayChargeDaySaving = true);
    try {
      await AutopayService.setAutopayChargeDayOfMonth(
        facilityId: tenant.facilityId,
        tenantId: tenant.id,
        chargeDayOfMonth: day,
      );
      if (mounted) {
        ref.invalidate(facilityTenantsProvider(tenant.facilityId));
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              day == null
                  ? 'Autopay charge date cleared (default billing applies).'
                  : 'Autopay charge date set to day $day of each month.',
            ),
            backgroundColor: AppTheme.success,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(ErrorMessageHelper.getUserFriendlyMessage(e)),
            backgroundColor: AppTheme.error,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _autopayChargeDaySaving = false);
    }
  }

  Future<void> _showAutopayConfirm(BuildContext context, TenantModel tenant, bool enable) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(enable ? 'Turn on Autopay?' : 'Turn off Autopay?'),
        content: Text(enable
            ? 'Rent will be charged automatically each month using the card on file for ${tenant.name}.'
            : 'Autopay will be disabled for ${tenant.name}. They will need to pay manually.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          ElevatedButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Yes')),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _autopayToggleLoading = true);
    try {
      await AutopayService.setTenantAutopay(
        facilityId: tenant.facilityId,
        tenantId: tenant.id,
        enabled: enable,
        source: 'FACILITY',
      );
      if (mounted) {
        ref.invalidate(facilityTenantsProvider(tenant.facilityId));
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(enable ? 'Autopay enabled' : 'Autopay disabled'), backgroundColor: AppTheme.success),
        );
      }
    } catch (e) {
      if (mounted) {
        String message = ErrorMessageHelper.getUserFriendlyMessage(e);
        if (e is FirebaseFunctionsException) {
          message = e.message ?? message;
          if (e.code == 'invalid-argument') {
            message = 'Invalid request. $message';
          } else if (e.code == 'failed-precondition') {
            if (message.contains('saved payment method') || message.contains('Add a card')) {
              message = 'Add a card for this tenant first, then turn on Autopay. Use "Open tenant to add card" below.';
            } else if (message.contains('Stripe') && (message.contains('not connected') || message.contains('onboarding'))) {
              message = 'Connect and complete Stripe for this facility in Settings or facility settings, then try again.';
            }
          }
        }
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(message), backgroundColor: AppTheme.error, duration: const Duration(seconds: 5)),
        );
      }
    } finally {
      if (mounted) setState(() => _autopayToggleLoading = false);
    }
  }

  Widget _buildAutopayActivitySection() {
    if (_selectedFacilityId.isEmpty) {
      return const Card(child: Padding(padding: EdgeInsets.all(24), child: Text('No facility selected.')));
    }
    return Consumer(
      builder: (context, ref, _) {
        final eventsAsync = ref.watch(autopayEventsProvider(_selectedFacilityId));
        return eventsAsync.when(
          loading: () => const Center(
            child: Padding(padding: EdgeInsets.all(24), child: CircularProgressIndicator()),
          ),
          error: (err, _) => Card(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.error_outline, size: 48, color: AppTheme.error),
                  const SizedBox(height: 12),
                  Text(
                    'Could not load autopay activity',
                    style: Theme.of(context).textTheme.titleSmall,
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    ErrorMessageHelper.getUserFriendlyMessage(err),
                    style: Theme.of(context).textTheme.bodySmall,
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 16),
                  ElevatedButton.icon(
                    onPressed: () => ref.invalidate(autopayEventsProvider(_selectedFacilityId)),
                    icon: const Icon(Icons.refresh, size: 18),
                    label: const Text('Retry'),
                  ),
                ],
              ),
            ),
          ),
          data: (events) {
            final selectedId = ref.watch(paymentsAutopaySelectedTenantIdProvider);
            var filtered = events;
            if (selectedId != null) {
              filtered = events.where((e) => e.tenantId == selectedId).toList();
            }
            if (filtered.isEmpty) {
              return Card(
                child: Padding(
                  padding: EdgeInsets.all(MediaQuery.of(context).size.width < Breakpoints.xs ? 16 : 24),
                  child: Text('No autopay activity yet', style: TextStyle(fontSize: MediaQuery.of(context).size.width < Breakpoints.xs ? 13 : null)),
                ),
              );
            }
            final isPhone = MediaQuery.of(context).size.width < Breakpoints.xs;
            final displayed = filtered.take(50).toList();
            if (isPhone) {
              return Card(
                child: ListView.separated(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  itemCount: displayed.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (context, i) {
                    final e = displayed[i];
                    return Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(e.action.displayLabel, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
                          Text(e.tenantName ?? '—', style: const TextStyle(fontSize: 12)),
                          Text('${DateFormat.yMMMd().add_Hm().format(e.createdAt)} · ${e.source.value}', style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
                          if (e.reason != null && e.reason!.isNotEmpty)
                            Text(e.reason!, style: const TextStyle(fontSize: 11), overflow: TextOverflow.ellipsis),
                        ],
                      ),
                    );
                  },
                ),
              );
            }
            return Card(
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: DataTable(
                  columns: const [
                    DataColumn(label: Text('Timestamp')),
                    DataColumn(label: Text('Tenant')),
                    DataColumn(label: Text('Action')),
                    DataColumn(label: Text('Actor')),
                    DataColumn(label: Text('Notes')),
                  ],
                  rows: displayed.map((e) => DataRow(
                    cells: [
                      DataCell(Text(DateFormat.yMMMd().add_Hm().format(e.createdAt))),
                      DataCell(Text(e.tenantName ?? '—')),
                      DataCell(Text(e.action.displayLabel)),
                      DataCell(Text(e.source.value)),
                      DataCell(Text(e.reason ?? '—')),
                    ],
                  )).toList(),
                ),
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildNoFacilitiesMessage() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.business,
            size: 64,
            color: AppTheme.textTertiary,
          ),
          const SizedBox(height: 16),
          Text(
            'No Facilities Found',
            style: Theme.of(context).textTheme.headlineSmall,
          ),
          const SizedBox(height: 8),
          Text(
            'You must create a storage facility before managing payments.',
            style: Theme.of(context).textTheme.bodyMedium,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 24),
          ElevatedButton(
            onPressed: () => context.go(AppRoute.facilityNew),
            child: const Text('Create Facility'),
          ),
        ],
      ),
    );
  }

  Widget _buildFilters() {
    return Container(
      padding: const EdgeInsets.all(16),
      child: Column(
        children: [
          // Facility selector
          Consumer(
            builder: (context, ref, child) {
              return ref.watch(authStateProvider).when(
                data: (user) {
                  if (user == null) return const SizedBox.shrink();
                  
                  return ref.watch(userFacilitiesProvider(user.uid)).when(
                    data: (facilities) {
                      if (facilities.isEmpty) return const SizedBox.shrink();
                      return Row(
                        children: [
                          Expanded(
                            child: DropdownButtonFormField<String>(
                              value: _selectedFacilityId.isNotEmpty ? _selectedFacilityId : null,
                              isExpanded: true,
                              decoration: const InputDecoration(
                                labelText: 'Facility',
                                border: OutlineInputBorder(),
                              ),
                              selectedItemBuilder: (context) {
                                final style = AppTheme.dropdownItemTextStyle.copyWith(
                                  color: Theme.of(context).colorScheme.onSurface,
                                );
                                return facilities.map((f) => Text(
                                  f.name,
                                  style: style,
                                  overflow: TextOverflow.ellipsis,
                                  maxLines: 1,
                                )).toList();
                              },
                              items: facilities.map((facility) {
                                return DropdownMenuItem(
                                  value: facility.id,
                                  child: Padding(
                                    padding: const EdgeInsets.symmetric(vertical: 8),
                                    child: Text(
                                      facility.name,
                                      style: AppTheme.dropdownItemTextStyle,
                                      softWrap: true,
                                    ),
                                  ),
                                );
                              }).toList(),
                              onChanged: (value) {
                                if (value != null) {
                                  setState(() => _selectedFacilityId = value);
                                  ref.read(activeFacilityIdProvider.notifier).setActiveFacilityId(value);
                                }
                              },
                            ),
                          ),
                          if (_selectedFacilityId.isNotEmpty) ...[
                            const SizedBox(width: AppConstants.spacingS),
                            IconButton(
                              onPressed: () => context.push('/units/map?facilityId=$_selectedFacilityId'),
                              icon: const Icon(Icons.map),
                              tooltip: 'View Map',
                              color: AppTheme.primaryBlue,
                            ),
                          ],
                        ],
                      );
                    },
                    loading: () => const Padding(
                      padding: EdgeInsets.all(AppConstants.spacingS),
                      child: Row(
                        children: [
                          SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                          SizedBox(width: AppConstants.spacingS),
                          Text('Loading facilities...'),
                        ],
                      ),
                    ),
                    error: (error, stackTrace) {
                      // If we already have a selected facility, suppress the error
                      // The provider might be retrying in the background
                      if (_selectedFacilityId.isNotEmpty) {
                        debugPrint('⚠️ Provider error but facility already selected, suppressing error: $error');
                        return const SizedBox.shrink();
                      }
                      
                      // Show error only if no facility is selected
                      return Container(
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: AppTheme.error.withOpacity(0.1),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: AppTheme.error.withOpacity(0.3)),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Icon(Icons.error_outline, color: AppTheme.error),
                                const SizedBox(width: AppConstants.spacingS),
                                Expanded(
                                  child: Text(
                                    ErrorMessageHelper.getUserFriendlyMessage(error),
                                    style: TextStyle(color: AppTheme.error),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 8),
                            ElevatedButton.icon(
                              onPressed: () {
                                _loadUserFacilities();
                                ref.invalidate(userFacilitiesProvider(user.uid));
                              },
                              icon: const Icon(Icons.refresh, size: 18),
                              label: const Text('Retry'),
                              style: ElevatedButton.styleFrom(
                                backgroundColor: AppTheme.error,
                                foregroundColor: AppTheme.textOnDark,
                              ),
                            ),
                          ],
                        ),
                      );
                    },
                  );
                },
                loading: () => const CircularProgressIndicator(),
                error: (_, __) => const Text('Error loading user'),
              );
            },
          ),
          const SizedBox(height: 16),
          Consumer(
            builder: (context, ref, _) {
              final tenantsAsync = ref.watch(facilityTenantsProvider(_selectedFacilityId));
              return tenantsAsync.when(
                data: (tenants) {
                  return Row(
                    children: [
                      SizedBox(
                        width: 200,
                        child: DropdownButtonFormField<String?>(
                          value: _selectedTenantIdFilter,
                          decoration: const InputDecoration(
                            labelText: 'Tenant',
                            border: OutlineInputBorder(),
                            isDense: true,
                          ),
                          items: [
                            const DropdownMenuItem(value: null, child: Text('All tenants')),
                            ...tenants.map((t) => DropdownMenuItem(value: t.id, child: Text('${t.name}${t.unitNumber.isNotEmpty ? ' (${t.unitNumber})' : ''}'))),
                          ],
                          onChanged: (v) => setState(() => _selectedTenantIdFilter = v),
                        ),
                      ),
                      const SizedBox(width: 12),
                      SizedBox(
                        width: 130,
                        child: OutlinedButton.icon(
                          icon: const Icon(Icons.calendar_today, size: 18),
                          label: Text(_filterDateStart == null ? 'Start' : DateFormat.yMMMd().format(_filterDateStart!)),
                          onPressed: () async {
                            final d = await showDatePicker(context: context, initialDate: _filterDateStart ?? DateTime.now(), firstDate: DateTime(2020), lastDate: DateTime.now().add(const Duration(days: 365)));
                            if (d != null) setState(() => _filterDateStart = d);
                          },
                        ),
                      ),
                      const SizedBox(width: 8),
                      SizedBox(
                        width: 130,
                        child: OutlinedButton.icon(
                          icon: const Icon(Icons.calendar_today, size: 18),
                          label: Text(_filterDateEnd == null ? 'End' : DateFormat.yMMMd().format(_filterDateEnd!)),
                          onPressed: () async {
                            final d = await showDatePicker(context: context, initialDate: _filterDateEnd ?? DateTime.now(), firstDate: DateTime(2020), lastDate: DateTime.now().add(const Duration(days: 365)));
                            if (d != null) setState(() => _filterDateEnd = d);
                          },
                        ),
                      ),
                      const SizedBox(width: 12),
                      DropdownButton<PaymentStatus?>(
                        value: _statusFilter,
                        hint: const Text('Status'),
                        items: [
                          const DropdownMenuItem(value: null, child: Text('All')),
                          const DropdownMenuItem(value: PaymentStatus.paid, child: Text('Succeeded')),
                          const DropdownMenuItem(value: PaymentStatus.completed, child: Text('Succeeded')),
                          const DropdownMenuItem(value: PaymentStatus.pending, child: Text('Pending')),
                          const DropdownMenuItem(value: PaymentStatus.failed, child: Text('Failed')),
                        ],
                        onChanged: (v) => setState(() => _statusFilter = v),
                      ),
                      const SizedBox(width: 8),
                      DropdownButton<PaymentMethod?>(
                        value: _methodFilter,
                        hint: const Text('Method'),
                        items: [
                          const DropdownMenuItem(value: null, child: Text('All')),
                          ...PaymentMethod.values.map((m) => DropdownMenuItem(value: m, child: Text(m.displayName))),
                        ],
                        onChanged: (v) => setState(() => _methodFilter = v),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: TextField(
                          decoration: const InputDecoration(
                            labelText: 'Search',
                            prefixIcon: Icon(Icons.search, size: 20),
                            border: OutlineInputBorder(),
                            isDense: true,
                          ),
                          onChanged: (v) => setState(() => _searchQuery = v),
                        ),
                      ),
                    ],
                  );
                },
                loading: () => const SizedBox(height: 48),
                error: (_, __) => const SizedBox(height: 48),
              );
            },
          ),
        ],
      ),
    );
  }

  Widget _buildStats() {
    return Consumer(
      builder: (context, ref, child) {
        return ref.watch(paymentListProvider(_selectedFacilityId)).when(
          data: (payments) {
            // Same list as the table — dollar totals, not payment counts with a "$" prefix.
            final active = payments.where((p) => p.isActive).toList();
            final fmt = NumberFormat.currency(symbol: '\$', decimalDigits: 2);

            final totalAmount =
                active.fold<double>(0, (acc, p) => acc + p.amount);

            final paidList = active.where((p) => p.isPaid).toList();
            final paidAmount =
                paidList.fold<double>(0, (acc, p) => acc + p.amount);

            final pendingList = active
                .where(
                  (p) =>
                      p.status == PaymentStatus.pending && !p.isOverdue,
                )
                .toList();
            final pendingAmount =
                pendingList.fold<double>(0, (acc, p) => acc + p.amount);

            final overdueList = active.where((p) => p.isOverdue).toList();
            final overdueAmount =
                overdueList.fold<double>(0, (acc, p) => acc + p.amount);

            return Container(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  Expanded(
                    child: _buildStatCard(
                      'Total',
                      fmt.format(totalAmount),
                      AppTheme.primaryBlue,
                      active.length,
                    ),
                  ),
                  const SizedBox(width: AppConstants.spacingS),
                  Expanded(
                    child: _buildStatCard(
                      'Paid',
                      fmt.format(paidAmount),
                      AppTheme.success,
                      paidList.length,
                    ),
                  ),
                  const SizedBox(width: AppConstants.spacingS),
                  Expanded(
                    child: _buildStatCard(
                      'Pending',
                      fmt.format(pendingAmount),
                      AppTheme.warning,
                      pendingList.length,
                    ),
                  ),
                  const SizedBox(width: AppConstants.spacingS),
                  Expanded(
                    child: _buildStatCard(
                      'Overdue',
                      fmt.format(overdueAmount),
                      AppTheme.error,
                      overdueList.length,
                    ),
                  ),
                ],
              ),
            );
          },
          loading: () => const SizedBox.shrink(),
          error: (_, __) => const SizedBox.shrink(),
        );
      },
    );
  }

  Widget _buildStatCard(String title, String amount, Color color, int count) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          children: [
            Text(
              title,
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 4),
            Text(
              amount,
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                color: color,
                fontWeight: FontWeight.bold,
              ),
            ),
            Text(
              '$count payments',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPaymentsList() {
    return Consumer(
      builder: (context, ref, child) {
        final paymentsAsync = ref.watch(paymentListProvider(_selectedFacilityId));
        final tenantsAsync = ref.watch(facilityTenantsProvider(_selectedFacilityId));
        return paymentsAsync.when(
          data: (payments) {
            final tenantById = <String, TenantModel>{};
            final tenants = tenantsAsync.whenOrNull(data: (v) => v);
            if (tenants != null) {
              for (final t in tenants) {
                tenantById[t.id] = t;
              }
            }

            String? tenantSubtitle(PaymentModel payment) {
              final snap = payment.snapshotPayerLine;
              if (snap != null) return snap;
              final t = tenantById[payment.tenantId];
              if (t != null) {
                final u = t.unitNumber.trim();
                return u.isNotEmpty ? '${t.name} · Unit $u' : t.name;
              }
              if (payment.tenantId.isEmpty) return null;
              return 'Tenant ID: ${payment.tenantId}';
            }

            // Apply filters
            final filteredPayments = payments.where((payment) {
              if (_selectedTenantIdFilter != null && payment.tenantId != _selectedTenantIdFilter) return false;
              if (_filterDateStart != null && payment.dueDate.isBefore(_filterDateStart!)) return false;
              if (_filterDateEnd != null && payment.dueDate.isAfter(_filterDateEnd!)) return false;
              if (_statusFilter != null && payment.status != _statusFilter) return false;
              if (_methodFilter != null && payment.method != _methodFilter) return false;
              if (_searchQuery.isNotEmpty) {
                final q = _searchQuery.toLowerCase();
                final t = tenantById[payment.tenantId];
                final tenantSearch = t == null
                    ? ''
                    : '${t.name} ${t.unitNumber}'.toLowerCase();
                final snapSearch =
                    '${payment.snapshotTenantName ?? ''} ${payment.snapshotUnitNumber ?? ''}'
                        .toLowerCase();
                if (!payment.formattedAmount.toLowerCase().contains(q) &&
                    !(payment.notes?.toLowerCase() ?? '').contains(q) &&
                    !payment.tenantId.toLowerCase().contains(q) &&
                    !tenantSearch.contains(q) &&
                    !snapSearch.contains(q)) {
                  return false;
                }
              }
              return true;
            }).toList();

            if (filteredPayments.isEmpty) {
              return Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      Icons.payment,
                      size: 64,
                      color: AppTheme.textTertiary,
                    ),
                    const SizedBox(height: AppConstants.spacingM),
                    Text(
                      'No payments found',
                      style: Theme.of(context).textTheme.headlineSmall,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Create your first payment or adjust your filters.',
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                  ],
                ),
              );
            }

            return ListView.builder(
              itemCount: filteredPayments.length,
              itemBuilder: (context, index) {
                final payment = filteredPayments[index];
                return _buildPaymentCard(payment, tenantSubtitle(payment));
              },
            );
          },
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (error, stackTrace) => Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  Icons.error,
                  size: 64,
                  color: AppTheme.error,
                ),
                const SizedBox(height: AppConstants.spacingM),
                Text(
                  'Error loading payments',
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
                const SizedBox(height: 8),
                Text(
                  ErrorMessageHelper.getUserFriendlyMessage(error),
                  style: Theme.of(context).textTheme.bodyMedium,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: AppConstants.spacingM),
                ElevatedButton(
                  onPressed: () {
                    ref.invalidate(paymentListProvider(_selectedFacilityId));
                  },
                  child: const Text('Retry'),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildPaymentCard(PaymentModel payment, String? tenantLine) {
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: _getStatusColor(payment.status),
          child: Icon(
            _getStatusIcon(payment.status),
            color: AppTheme.textOnDark,
          ),
        ),
        title: Text(
          payment.formattedAmount,
          style: Theme.of(context).textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.bold,
          ),
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (tenantLine != null) ...[
              Text(
                tenantLine,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
              ),
              const SizedBox(height: 4),
            ],
            Text('Due: ${_formatDate(payment.dueDate)}'),
            if (payment.isOverdue)
              Text(
                'Overdue by ${payment.daysOverdue} days',
                style: TextStyle(color: AppTheme.error),
              ),
            Text('Method: ${payment.methodDisplayName}'),
            if (payment.notes != null && payment.notes!.trim().isNotEmpty)
              Text('Notes: ${payment.notes}'),
          ],
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (payment.status == PaymentStatus.pending)
              IconButton(
                icon: const Icon(Icons.payment),
                onPressed: () => _processPayment(payment),
              ),
            IconButton(
              icon: const Icon(Icons.arrow_forward_ios),
              onPressed: () => _navigateToPaymentDetail(payment),
            ),
          ],
        ),
        onTap: () => _navigateToPaymentDetail(payment),
      ),
    );
  }

  Color _getStatusColor(PaymentStatus status) {
    switch (status) {
      case PaymentStatus.pending:
        return AppTheme.warning;
      case PaymentStatus.paid:
        return AppTheme.success;
      case PaymentStatus.completed:
        return AppTheme.success;
      case PaymentStatus.failed:
        return AppTheme.error;
      case PaymentStatus.refunded:
        return AppTheme.primaryBlue;
      case PaymentStatus.cancelled:
        return AppTheme.textTertiary;
    }
  }

  IconData _getStatusIcon(PaymentStatus status) {
    switch (status) {
      case PaymentStatus.pending:
        return Icons.pending;
      case PaymentStatus.paid:
        return Icons.check;
      case PaymentStatus.completed:
        return Icons.check;
      case PaymentStatus.failed:
        return Icons.error;
      case PaymentStatus.refunded:
        return Icons.refresh;
      case PaymentStatus.cancelled:
        return Icons.cancel;
    }
  }

  String _formatDate(DateTime date) {
    return '${date.month}/${date.day}/${date.year}';
  }

  void _navigateToCreatePayment() {
    if (_selectedFacilityId.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Please select a facility first'),
          backgroundColor: AppTheme.warning,
        ),
      );
      return;
    }
    
    context.push(
      '${AppRoute.paymentCreate}?facilityId=$_selectedFacilityId',
    ).then((_) {
      // Refresh providers when returning from payment creation
      ref.invalidate(paymentListProvider(_selectedFacilityId));
      ref.invalidate(paymentStatsProvider(_selectedFacilityId));
    });
  }

  void _navigateToPaymentDetail(PaymentModel payment) {
    context.push(
      AppRoute.paymentDetail,
      extra: payment,
    ).then((_) {
      // Refresh providers when returning from payment detail
      ref.invalidate(paymentListProvider(_selectedFacilityId));
      ref.invalidate(paymentStatsProvider(_selectedFacilityId));
    });
  }

  void _processPayment(PaymentModel payment) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Process Payment'),
        content: Text('Process payment of ${payment.formattedAmount}?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () async {
              Navigator.of(context).pop();
              try {
                await ref.read(paymentOperationsProvider.notifier).processPayment(
                  facilityId: _selectedFacilityId,
                  paymentId: payment.id,
                  method: payment.method,
                );
                if (!context.mounted) return;
                ref.invalidate(paymentListProvider(_selectedFacilityId));
                ref.invalidate(paymentStatsProvider(_selectedFacilityId));
              } catch (e) {
                if (!context.mounted) return;
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text(ErrorMessageHelper.getUserFriendlyMessage(e)),
                    backgroundColor: AppTheme.error,
                  ),
                );
              }
            },
            child: const Text('Process'),
          ),
        ],
      ),
    );
  }
}

class _TabButton extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _TabButton({required this.label, required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: selected ? AppTheme.primaryBlue.withOpacity(0.12) : Colors.transparent,
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
          child: Text(
            label,
            style: Theme.of(context).textTheme.titleSmall?.copyWith(
              fontWeight: selected ? FontWeight.w600 : null,
              color: selected ? AppTheme.primaryBlue : null,
            ),
          ),
        ),
      ),
    );
  }
}
