import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sfcapp/providers/tenant_provider.dart';
import 'package:sfcapp/providers/permission_provider.dart';
import 'package:sfcapp/providers/auth_provider.dart';
import 'package:sfcapp/providers/facility_provider.dart';
import 'package:sfcapp/providers/active_facility_provider.dart';
import 'package:sfcapp/models/tenant_model.dart';
import 'package:sfcapp/models/unit_model.dart';
import 'package:sfcapp/providers/unit_provider.dart';
import 'package:sfcapp/utils/unit_areas.dart';
import 'package:sfcapp/models/facility_model.dart';
import 'package:sfcapp/services/facility_creator_account_service.dart';
import 'package:sfcapp/services/tenant_service.dart';
import 'package:sfcapp/services/tenant_portal_service.dart';
import 'package:sfcapp/theme/app_theme.dart';
import 'package:sfcapp/constants/app_constants.dart';
import 'package:sfcapp/router/app_route.dart';
import 'package:sfcapp/utils/callable_failure.dart';
import 'package:sfcapp/utils/error_message_helper.dart';
import 'package:sfcapp/utils/setup_retry_controller.dart';
import 'package:sfcapp/screens/tenant_creation_screen.dart';
import 'package:sfcapp/screens/tenant_edit_screen.dart';
import 'package:sfcapp/services/late_logic_service.dart';
import 'package:sfcapp/services/permission_service.dart';
import 'package:sfcapp/models/permission_model.dart';
import 'package:sfcapp/widgets/confirm_units_freed_dialog.dart';

/// Grace period for delinquency badge (uses facility Billing Settings when available).
final _facilityGracePeriodProvider = FutureProvider.family<int, String>((ref, facilityId) async {
  if (facilityId.isEmpty) return 3;
  return LateLogicService.getFacilityGracePeriodDays(facilityId);
});

class ClientListScreen extends ConsumerStatefulWidget {
  const ClientListScreen({super.key});

  @override
  ConsumerState<ClientListScreen> createState() => _ClientListScreenState();
}

class _ClientListScreenState extends ConsumerState<ClientListScreen> {
  final _searchController = TextEditingController();
  String _selectedFacilityId = '';
  bool _isSelectionMode = false;
  final Set<String> _selectedTenantIds = {};
  bool _hasInitializedFacility = false;
  final SetupRetryController _setupRetry = SetupRetryController();

  @override
  void initState() {
    super.initState();
    // Ensure account exists on init
    WidgetsBinding.instance.addPostFrameCallback((_) {
      // The Area filter starts at All areas each time the list opens, as the
      // search box starts empty.
      if (mounted) ref.read(tenantAreaFilterProvider.notifier).state = null;
      _ensureAccountExists();
    });
  }

  @override
  void dispose() {
    _setupRetry.cancel();
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _ensureAccountExists() async {
    try {
      final authState = ref.read(authStateProvider);
      if (authState.hasValue && authState.value != null) {
        // Ensure account exists (for free trial users)
        try {
          await FacilityCreatorAccountService.getOrCreateAccountForCurrentUser();
        } catch (accountError) {
          // Account creation is non-critical, log but continue
          if (mounted) {
            debugPrint('⚠️ Could not ensure account exists: $accountError');
          }
        }
      }
    } catch (e) {
      if (mounted) {
        debugPrint('⚠️ Error ensuring account exists: $e');
      }
    }
  }

  Future<void> _retrySetupAndRefresh({String? facilityId}) async {
    final authState = ref.read(authStateProvider);
    if (!authState.hasValue || authState.value == null) return;
    final user = authState.value!;

    await _ensureAccountExists();
    ref.invalidate(userFacilitiesProvider(user.uid));
    if (facilityId != null && facilityId.isNotEmpty && facilityId != 'all') {
      ref.invalidate(facilityTenantsProvider(facilityId));
    }
  }

  @override
  Widget build(BuildContext context) {
    final authState = ref.watch(authStateProvider);

    // Riverpod: ref.listen must run on every build, not only inside AsyncValue.when(data:).
    // Placing it in the data branch caused uncaught errors and a frozen Tenants UI.
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

      final activeId = next.whenOrNull(data: (d) => d);
      final newLocal = activeId ?? 'all';
      if (newLocal == _selectedFacilityId) return;
      if (activeId == null || facilities.any((f) => f.id == activeId)) {
        setState(() {
          _selectedFacilityId = newLocal;
          _hasInitializedFacility = true;
        });
        ref.read(tenantAreaFilterProvider.notifier).state = null;
      }
    });

    return authState.when(
      data: (user) {
        if (user == null) {
          return const Scaffold(
            body: Center(child: Text('Please sign in to view tenants')),
          );
        }

        // Watch facilities provider and auto-select first facility
        final facilitiesAsync = ref.watch(userFacilitiesProvider(user.uid));
        
        return facilitiesAsync.when(
          data: (facilities) {
            _setupRetry.reset();
            // Auto-select facility: prefer active facility (global context) so dropdowns stay in sync
            if (!_hasInitializedFacility && facilities.isNotEmpty && _selectedFacilityId.isEmpty) {
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (mounted) {
                  final activeId = ref.read(activeFacilityIdProvider).whenOrNull(data: (d) => d);
                  final initialId = activeId == null
                      ? 'all'
                      : (facilities.any((f) => f.id == activeId) ? activeId : facilities.first.id);
                  setState(() {
                    _selectedFacilityId = initialId;
                    _hasInitializedFacility = true;
                  });
                }
              });
            }
            
            // If facilities become empty, reset selection
            if (facilities.isEmpty && _selectedFacilityId.isNotEmpty) {
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (mounted) {
                  setState(() {
                    _selectedFacilityId = '';
                    _hasInitializedFacility = false;
                  });
                }
              });
            }

            return _buildContent(facilities);
          },
          loading: () => const Scaffold(
            body: Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  CircularProgressIndicator(),
                  SizedBox(height: AppConstants.spacingM),
                  Text('Loading facilities...'),
                ],
              ),
            ),
          ),
          error: (error, stackTrace) {
            final errorMessage = error.toString();
            final isPermissionError = errorMessage.contains('permission-denied') ||
                errorMessage.contains('Missing or insufficient permissions');
            if (isPermissionError && _setupRetry.canRetry) {
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (mounted) {
                  _setupRetry.schedule(
                    onRetry: () {
                      if (!mounted) return;
                      _retrySetupAndRefresh();
                    },
                  );
                }
              });
            }
            String userMessage;

            if (isPermissionError) {
              userMessage = 'Permission denied. Please check your account status or contact support.';
            } else if (errorMessage.contains('Not signed in')) {
              userMessage = 'Please sign in to view your facilities.';
            } else {
              userMessage = 'Error loading facilities: ${error.toString()}';
            }
            
            return Scaffold(
              body: Center(
                child: Padding(
                  padding: const EdgeInsets.all(AppConstants.spacingL),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Icon(Icons.error_outline, size: 64, color: AppTheme.error),
                      const SizedBox(height: AppConstants.spacingM),
                      Text(
                        'Error loading facilities',
                        style: const TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.bold,
                          color: AppTheme.error,
                        ),
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 12),
                      Text(
                        userMessage,
                        style: const TextStyle(
                          color: AppTheme.textSecondary,
                          fontSize: 14,
                        ),
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 24),
                      ElevatedButton.icon(
                        onPressed: () async {
                          await _retrySetupAndRefresh();
                        },
                        icon: const Icon(Icons.refresh),
                        label: const Text('Retry'),
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        );
      },
      loading: () => const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      ),
      error: (error, stackTrace) => Scaffold(
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.error, size: 64, color: AppTheme.error),
              const SizedBox(height: 16),
              const Text('Authentication Error'),
              const SizedBox(height: 8),
              Text(ErrorMessageHelper.getUserFriendlyMessage(error)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildContent(List<FacilityModel> facilities) {
    final searchQuery = ref.watch(tenantSearchProvider);
    final sortOption = ref.watch(tenantSortProvider);
    final tenantsAsync = _selectedFacilityId == 'all'
        ? ref.watch(multiFacilityTenantsProvider('all')).whenData((tenants) =>
            filterAndSortTenantsForDisplay(tenants, searchQuery, sortOption))
        : ref.watch(filteredTenantsProvider(_selectedFacilityId));
    final graceAsync = ref.watch(_facilityGracePeriodProvider(_selectedFacilityId == 'all' ? '' : _selectedFacilityId));
    final gracePeriodDays = graceAsync.whenOrNull(data: (d) => d) ?? 3;
    final permFacilityId =
        _selectedFacilityId.isEmpty || _selectedFacilityId == 'all' ? '' : _selectedFacilityId;
    final canDeleteTenant = ref
        .watch(canDeleteTenantAtFacilityProvider(permFacilityId))
        .maybeWhen(data: (v) => v, orElse: () => false);
    // Areas are per facility, so the Area filter and the area beside each
    // unit number are for one facility's list, not All Facilities.
    final facilityUnits = permFacilityId.isEmpty
        ? const <UnitModel>[]
        : (ref.watch(facilityUnitsProvider(permFacilityId)).value ??
            const <UnitModel>[]);
    final areaOptions = unitAreaFilterOptions(facilityUnits);
    final areaIndex =
        areaOptions.isEmpty ? null : TenantUnitAreaIndex(facilityUnits);
    final areaFilter = effectiveUnitAreaFilter(
        ref.watch(tenantAreaFilterProvider), areaOptions);

    return Column(
            children: [
              // Search and Filter Section
              Builder(
                builder: (context) {
                  final cs = Theme.of(context).colorScheme;
                  return Container(
                    padding: const EdgeInsets.all(AppConstants.spacingM),
                    color: cs.surfaceContainerHighest,
                    child: Column(
                      children: [
                        // Search Bar
                        TextField(
                          controller: _searchController,
                          decoration: InputDecoration(
                            hintText: 'Search tenants...',
                            prefixIcon: const Icon(Icons.search),
                            suffixIcon: _searchController.text.isNotEmpty
                                ? IconButton(
                                    onPressed: () {
                                      _searchController.clear();
                                      ref.read(tenantSearchProvider.notifier).state = '';
                                    },
                                    icon: const Icon(Icons.clear),
                                  )
                                : null,
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(8),
                            ),
                            filled: true,
                            fillColor: cs.surface,
                          ),
                      onChanged: (value) {
                        ref.read(tenantSearchProvider.notifier).state = value;
                      },
                    ),
                    const SizedBox(height: AppConstants.spacingM),
                    
                    // Sort and Filter Row
                    Row(
                      children: [
                        Icon(Icons.sort, size: 20, color: cs.onSurfaceVariant),
                        const SizedBox(width: AppConstants.spacingS),
                        Text('Sort by: ', style: TextStyle(color: cs.onSurface)),
                        const SizedBox(width: AppConstants.spacingS),
                        Expanded(
                          child: DropdownButtonFormField<TenantSortOption>(
                            value: ref.watch(tenantSortProvider),
                            decoration: const InputDecoration(
                              border: OutlineInputBorder(),
                              contentPadding: EdgeInsets.symmetric(horizontal: AppConstants.spacingM - 4, vertical: AppConstants.spacingS),
                              isDense: true,
                            ),
                            items: const [
                              DropdownMenuItem(
                                value: TenantSortOption.nameAsc,
                                child: Text('Name (A-Z)'),
                              ),
                              DropdownMenuItem(
                                value: TenantSortOption.nameDesc,
                                child: Text('Name (Z-A)'),
                              ),
                              DropdownMenuItem(
                                value: TenantSortOption.unitNumberAsc,
                                child: Text('Unit Number (Low to High)'),
                              ),
                              DropdownMenuItem(
                                value: TenantSortOption.unitNumberDesc,
                                child: Text('Unit Number (High to Low)'),
                              ),
                              DropdownMenuItem(
                                value: TenantSortOption.dateCreatedDesc,
                                child: Text('Date Created (Newest First)'),
                              ),
                              DropdownMenuItem(
                                value: TenantSortOption.dateCreatedAsc,
                                child: Text('Date Created (Oldest First)'),
                              ),
                              DropdownMenuItem(
                                value: TenantSortOption.monthlyRateAsc,
                                child: Text('Monthly Rate (Low to High)'),
                              ),
                              DropdownMenuItem(
                                value: TenantSortOption.monthlyRateDesc,
                                child: Text('Monthly Rate (High to Low)'),
                              ),
                              DropdownMenuItem(
                                value: TenantSortOption.status,
                                child: Text('Status (Active First)'),
                              ),
                            ],
                            onChanged: (value) {
                              if (value != null) {
                                ref.read(tenantSortProvider.notifier).state = value;
                              }
                            },
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: AppConstants.spacingM),

                    // Area filter: only for one facility whose units have
                    // areas.
                    if (areaOptions.isNotEmpty) ...[
                      Row(
                        children: [
                          Icon(Icons.place_outlined, size: 20, color: cs.onSurfaceVariant),
                          const SizedBox(width: AppConstants.spacingS),
                          Text('Area: ', style: TextStyle(color: cs.onSurface)),
                          const SizedBox(width: AppConstants.spacingS),
                          Expanded(
                            child: DropdownButtonFormField<String?>(
                              key: const ValueKey('tenant-area-filter'),
                              value: areaFilter,
                              isExpanded: true,
                              decoration: const InputDecoration(
                                border: OutlineInputBorder(),
                                contentPadding: EdgeInsets.symmetric(horizontal: AppConstants.spacingM - 4, vertical: AppConstants.spacingS),
                                isDense: true,
                              ),
                              items: [
                                const DropdownMenuItem<String?>(
                                  value: null,
                                  child: Text('All areas'),
                                ),
                                for (final option in areaOptions)
                                  DropdownMenuItem<String?>(
                                    value: option,
                                    child: Text(unitAreaFilterLabel(option), overflow: TextOverflow.ellipsis),
                                  ),
                              ],
                              onChanged: (value) {
                                // Bulk actions act on the selected tenants
                                // in the list shown, so start over.
                                setState(() => _selectedTenantIds.clear());
                                ref.read(tenantAreaFilterProvider.notifier).state = value;
                              },
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: AppConstants.spacingM),
                    ],
                    
                    // Selection Mode Controls
                    if (_isSelectionMode && _selectedFacilityId.isNotEmpty)
                      Container(
                        padding: const EdgeInsets.symmetric(vertical: AppConstants.spacingS),
                        decoration: BoxDecoration(
                          color: cs.primary.withValues(alpha: 0.1),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Row(
                          children: [
                            IconButton(
                              onPressed: () {
                                setState(() {
                                  _isSelectionMode = false;
                                  _selectedTenantIds.clear();
                                });
                              },
                              icon: const Icon(Icons.close),
                              tooltip: 'Exit Selection Mode',
                            ),
                            Text(
                              '${_selectedTenantIds.length} selected',
                              style: const TextStyle(fontWeight: FontWeight.bold),
                            ),
                            const Spacer(),
                            Builder(
                              builder: (context) {
                                final tenantsAsync = ref.watch(filteredTenantsProvider(_selectedFacilityId));
                                return tenantsAsync.when(
                                  data: (tenants) {
                                    final allSelected = tenants.isNotEmpty && 
                                        _selectedTenantIds.length == tenants.length &&
                                        tenants.every((t) => _selectedTenantIds.contains(t.id));
                                    
                                    return TextButton.icon(
                                      onPressed: () {
                                        setState(() {
                                          if (allSelected) {
                                            _selectedTenantIds.clear();
                                          } else {
                                            _selectedTenantIds.clear();
                                            _selectedTenantIds.addAll(tenants.map((t) => t.id));
                                          }
                                        });
                                      },
                                      icon: const Icon(Icons.select_all),
                                      label: Text(allSelected ? 'Deselect All' : 'Select All'),
                                    );
                                  },
                                  loading: () => TextButton.icon(
                                    onPressed: null,
                                    icon: const Icon(Icons.select_all),
                                    label: const Text('Select All'),
                                  ),
                                  error: (_, __) => TextButton.icon(
                                    onPressed: null,
                                    icon: const Icon(Icons.select_all),
                                    label: const Text('Select All'),
                                  ),
                                );
                              },
                            ),
                            const SizedBox(width: 8),
                            OutlinedButton.icon(
                              onPressed: _selectedTenantIds.isEmpty ? null : () => _inviteSelectedTenants(),
                              icon: const Icon(Icons.forward_to_inbox_outlined),
                              label: Text('Email invites (${_selectedTenantIds.length})'),
                            ),
                            const SizedBox(width: 8),
                            OutlinedButton.icon(
                              onPressed: _selectedTenantIds.isEmpty
                                  ? null
                                  : () => _recordSmsConsentForSelected(),
                              icon: const Icon(Icons.sms_outlined),
                              label: Text('Record SMS consent (${_selectedTenantIds.length})'),
                            ),
                            const SizedBox(width: 8),
                            ElevatedButton.icon(
                              onPressed: (_selectedTenantIds.isEmpty || !canDeleteTenant)
                                  ? null
                                  : () => _deleteSelectedTenants(),
                              icon: const Icon(Icons.delete),
                              label: Text('Delete (${_selectedTenantIds.length})'),
                              style: ElevatedButton.styleFrom(
                                backgroundColor: cs.error,
                                foregroundColor: cs.onError,
                                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                              ),
                            ),
                          ],
                        ),
                      ),
                    
                    // Facility Filter and Create Button Row
                    if (facilities.isNotEmpty)
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              const Icon(Icons.business, size: 20),
                              const SizedBox(width: AppConstants.spacingS),
                              const Text('Facility: '),
                              const SizedBox(width: AppConstants.spacingS),
                              Expanded(
                                child: DropdownButtonFormField<String>(
                                  value: _selectedFacilityId.isEmpty ? 'all' : _selectedFacilityId,
                                  isExpanded: true,
                                  decoration: const InputDecoration(
                                    border: OutlineInputBorder(),
                                    contentPadding: EdgeInsets.symmetric(horizontal: AppConstants.spacingM - 4, vertical: AppConstants.spacingS),
                                  ),
                                  selectedItemBuilder: (context) {
                                    final colorScheme = Theme.of(context).colorScheme;
                                    final style = AppTheme.dropdownItemTextStyle.copyWith(color: colorScheme.onSurface);
                                    return [
                                      Text(
                                        'All Facilities',
                                        overflow: TextOverflow.ellipsis,
                                        maxLines: 1,
                                        style: style,
                                      ),
                                      ...facilities.map((f) => Text(
                                        f.name,
                                        overflow: TextOverflow.ellipsis,
                                        maxLines: 1,
                                        style: style,
                                      )),
                                    ];
                                  },
                                  items: [
                                    DropdownMenuItem<String>(
                                      value: 'all',
                                      child: Padding(
                                        padding: const EdgeInsets.symmetric(vertical: 8),
                                        child: Text(
                                          'All Facilities',
                                          style: AppTheme.dropdownItemTextStyle,
                                          softWrap: true,
                                        ),
                                      ),
                                    ),
                                    ...facilities.map((facility) {
                                      return DropdownMenuItem<String>(
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
                                    }),
                                  ],
                                  onChanged: _isSelectionMode
                                      ? null
                                      : (value) async {
                                          final newId = value ?? '';
                                          setState(() {
                                            _selectedFacilityId = newId;
                                            _searchController.clear();
                                            ref.read(tenantSearchProvider.notifier).state = '';
                                            ref.read(tenantAreaFilterProvider.notifier).state = null;
                                            _selectedTenantIds.clear();
                                          });
                                          await ref.read(activeFacilityIdProvider.notifier).setActiveFacilityId(
                                            newId.isEmpty || newId == 'all' ? null : newId,
                                          );
                                        },
                                ),
                              ),
                            ],
                          ),
                          if (_selectedFacilityId.isNotEmpty && _selectedFacilityId != 'all' && !_isSelectionMode) ...[
                            const SizedBox(height: AppConstants.spacingS),
                            Wrap(
                              spacing: 8,
                              runSpacing: 8,
                              children: [
                                IconButton(
                                  onPressed: () => context.push('/units/map?facilityId=$_selectedFacilityId'),
                                  icon: const Icon(Icons.map),
                                  tooltip: 'View Map',
                                  color: AppTheme.primaryBlue,
                                ),
                                // Import CSV button
                                OutlinedButton.icon(
                                  onPressed: () => context.push(
                                        AppRoute.tenantCsvImport,
                                        extra: {'facilityId': _selectedFacilityId},
                                      ),
                                  icon: const Icon(Icons.upload_file),
                                  label: const Text('Import CSV'),
                                  style: OutlinedButton.styleFrom(
                                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                                  ),
                                ),
                                // Selection Mode Toggle - Make it more prominent
                                ElevatedButton.icon(
                                  onPressed: () {
                                    setState(() {
                                      _isSelectionMode = true;
                                      _selectedTenantIds.clear();
                                    });
                                  },
                                  icon: const Icon(Icons.checklist),
                                  label: const Text('Select Multiple'),
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: AppTheme.primaryBlue,
                                    foregroundColor: AppTheme.textOnDark,
                                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                                  ),
                                ),
                                // Create Tenant button
                                ElevatedButton.icon(
                                  onPressed: () => _showCreateTenantDialog(context, ref, mounted, _selectedFacilityId),
                                  icon: const Icon(Icons.person_add),
                                  label: const Text('Create Tenant'),
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: AppTheme.primaryBlue,
                                    foregroundColor: AppTheme.textOnDark,
                                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ],
                      )
                    else
                      // Show create button even when no facilities (will show error)
                      Row(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          ElevatedButton.icon(
                            onPressed: () => _showCreateTenantDialog(context, ref, mounted, _selectedFacilityId),
                            icon: const Icon(Icons.person_add),
                            label: const Text('Create Tenant'),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: AppTheme.primaryBlue,
                              foregroundColor: AppTheme.textOnDark,
                              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                            ),
                          ),
                        ],
                      ),
                  ],
                ),
              );
            },
          ),
              
              // Tenants List
              Expanded(
                child: _selectedFacilityId.isEmpty && facilities.isNotEmpty
                    ? Center(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(
                              Icons.business_outlined,
                              size: 64,
                              color: AppTheme.textTertiary,
                            ),
                            const SizedBox(height: AppConstants.spacingM),
                            Text(
                              'Please select a facility to view tenants',
                              style: TextStyle(
                                fontSize: 18,
                                color: AppTheme.textSecondary,
                              ),
                            ),
                          ],
                        ),
                      )
                    : tenantsAsync.when(
                        data: (tenants) {
                          if (tenants.isEmpty) {
                            return Center(
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Icon(
                                    Icons.people_outline,
                                    size: 64,
                                    color: AppTheme.textTertiary,
                                  ),
                                  const SizedBox(height: AppConstants.spacingM),
                                  Text(
                                    _searchController.text.isNotEmpty
                                        ? 'No tenants found matching "${_searchController.text}"'
                                        : areaFilter != null
                                            ? 'No tenants in ${unitAreaFilterLabel(areaFilter)}'
                                        : _selectedFacilityId.isEmpty
                                            ? 'No facility selected'
                                            : 'No tenants found',
                                    style: TextStyle(
                                      fontSize: 18,
                                      color: AppTheme.textSecondary,
                                    ),
                                  ),
                                  const SizedBox(height: AppConstants.spacingS),
                                  if (_searchController.text.isEmpty && areaFilter == null && _selectedFacilityId.isNotEmpty)
                                    Text(
                                      'Add your first tenant to get started',
                                      style: TextStyle(
                                        color: AppTheme.textTertiary,
                                      ),
                                    ),
                                ],
                              ),
                            );
                          }

                          return ListView.builder(
                            itemCount: tenants.length,
                            itemBuilder: (context, index) {
                              final tenant = tenants[index];
                              return _buildTenantCard(
                                tenant,
                                areas: areaIndex?.areasFor(tenant) ?? const [],
                                gracePeriodDays: gracePeriodDays,
                                canDeleteTenant: canDeleteTenant && _selectedFacilityId != 'all',
                              );
                            },
                          );
                        },
                        loading: () => const Center(
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              CircularProgressIndicator(),
                              SizedBox(height: AppConstants.spacingM),
                              Text('Loading tenants...'),
                            ],
                          ),
                        ),
                        error: (error, stackTrace) {
                          final errorStr = error.toString();
                          bool isPermissionError = errorStr.contains('permission-denied') || 
                                                  errorStr.contains('Missing or insufficient permissions');
                          if (isPermissionError && _setupRetry.canRetry) {
                            WidgetsBinding.instance.addPostFrameCallback((_) {
                              if (mounted) {
                                _setupRetry.schedule(
                                  onRetry: () {
                                    if (!mounted) return;
                                    _retrySetupAndRefresh(
                                      facilityId: _selectedFacilityId,
                                    );
                                  },
                                );
                              }
                            });
                          }
                          
                          return Center(
                            child: Padding(
                              padding: const EdgeInsets.all(AppConstants.spacingL),
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  const Icon(Icons.error_outline, size: 64, color: AppTheme.error),
                                  const SizedBox(height: AppConstants.spacingM),
                                  Text(
                                    isPermissionError 
                                      ? 'Permission Error' 
                                      : 'Error loading tenants',
                                    style: const TextStyle(
                                      fontSize: 20,
                                      fontWeight: FontWeight.bold,
                                      color: AppTheme.error,
                                    ),
                                    textAlign: TextAlign.center,
                                  ),
                                  const SizedBox(height: 12),
                                  Text(
                                    isPermissionError
                                      ? 'You don\'t have permission to view tenants. This may happen if:\n\n'
                                        '• Your account needs to be set up\n'
                                        '• Your trial or subscription has expired\n'
                                        '• There was an issue with facility permissions\n\n'
                                        'Please try refreshing or contact support if the issue persists.'
                                      : errorStr,
                                    style: const TextStyle(
                                      color: AppTheme.textSecondary,
                                      fontSize: 14,
                                    ),
                                    textAlign: TextAlign.center,
                                  ),
                                  const SizedBox(height: 24),
                                  Row(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    children: [
                                      ElevatedButton.icon(
                                        onPressed: () async {
                                          await _retrySetupAndRefresh(
                                            facilityId: _selectedFacilityId,
                                          );
                                        },
                                        icon: const Icon(Icons.refresh),
                                        label: const Text('Retry'),
                                      ),
                                      if (isPermissionError) ...[
                                        const SizedBox(width: 12),
                                        OutlinedButton.icon(
                                          onPressed: () {
                                            // Navigate to subscription screen to check account status
                                            context.push(AppRoute.subscription);
                                          },
                                          icon: const Icon(Icons.info_outline),
                                          label: const Text('Check Account'),
                                        ),
                                      ],
                                    ],
                                  ),
                                ],
                              ),
                            ),
                          );
                        },
                      ),
              ),
            ]
    );
  }

  Widget _buildTenantCard(
    TenantModel tenant, {
    List<String> areas = const [],
    int? gracePeriodDays,
    bool canDeleteTenant = false,
  }) {
    final grace = gracePeriodDays ?? 3;
    final isLate = LateLogicService.isTenantLate(tenant, gracePeriodDays: grace);
    final daysLate = LateLogicService.getTenantDaysLate(tenant, gracePeriodDays: grace);
    final isSelected = _selectedTenantIds.contains(tenant.id);

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: AppConstants.spacingM, vertical: AppConstants.spacingXS),
      color: isSelected ? AppTheme.primaryBlue.withValues(alpha: 0.1) : null,
      child: ListTile(
        leading: _isSelectionMode
            ? Checkbox(
                value: isSelected,
                onChanged: (value) {
                  setState(() {
                    if (value == true) {
                      _selectedTenantIds.add(tenant.id);
                    } else {
                      _selectedTenantIds.remove(tenant.id);
                    }
                  });
                },
              )
            : CircleAvatar(
                backgroundColor: tenant.isActive 
                    ? (isLate ? AppTheme.error : AppTheme.success) 
                    : AppTheme.textTertiary,
                child: Text(
                  tenant.name.isNotEmpty ? tenant.name[0].toUpperCase() : '?',
                  style: const TextStyle(
                    color: AppTheme.textOnDark,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
        title: Text(
          tenant.name,
          style: const TextStyle(fontWeight: FontWeight.bold),
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(areas.isEmpty
                ? 'Unit: ${tenant.unitNumber}'
                : 'Unit: ${tenant.unitNumber} · ${areas.join(', ')}'),
            Text('Email: ${tenant.email}'),
            Text('Phone: ${tenant.phone}'),
            Text(
              'Rate: \$${tenant.monthlyRate.toStringAsFixed(2)}/month',
              style: const TextStyle(fontWeight: FontWeight.w500),
            ),
            if (isLate && daysLate > 0)
              Container(
                margin: const EdgeInsets.only(top: AppConstants.spacingXS),
                padding: const EdgeInsets.symmetric(horizontal: AppConstants.spacingS, vertical: AppConstants.spacingXS / 2),
                decoration: BoxDecoration(
                  color: AppTheme.error.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: AppTheme.error.withValues(alpha: 0.3)),
                ),
                child: Text(
                  'LATE PAYMENT - $daysLate ${daysLate == 1 ? 'day' : 'days'}',
                  style: const TextStyle(
                    color: AppTheme.error,
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
          ],
        ),
        trailing: _isSelectionMode
            ? null
            : PopupMenuButton<String>(
                onSelected: (value) async {
                  switch (value) {
                    case 'view':
                      unawaited(context.push(AppRoute.tenantDetail, extra: tenant));
                      break;
                    case 'edit':
                      unawaited(context.push(
                        AppRoute.legacyScreen,
                        extra: TenantEditScreen(
                          tenant: tenant,
                          facilityIdOverride: _selectedFacilityId.isNotEmpty ? _selectedFacilityId : null,
                        ),
                      ));
                      break;
                    case 'archive':
                      await _archiveTenant(tenant);
                      break;
                    case 'invite':
                      await _inviteTenants([tenant]);
                      break;
                    case 'select':
                      setState(() {
                        _isSelectionMode = true;
                        _selectedTenantIds.clear();
                        _selectedTenantIds.add(tenant.id);
                      });
                      break;
                    case 'delete':
                      await _deleteTenant(tenant);
                      break;
                  }
                },
                itemBuilder: (context) => [
                  const PopupMenuItem(
                    value: 'view',
                    child: Row(
                      children: [
                        Icon(Icons.visibility),
                        SizedBox(width: 8),
                        Text('View Details'),
                      ],
                    ),
                  ),
                  const PopupMenuItem(
                    value: 'edit',
                    child: Row(
                      children: [
                        Icon(Icons.edit),
                        SizedBox(width: 8),
                        Text('Edit'),
                      ],
                    ),
                  ),
                  const PopupMenuItem(
                    value: 'archive',
                    child: Row(
                      children: [
                        Icon(Icons.archive),
                        SizedBox(width: 8),
                        Text('Archive'),
                      ],
                    ),
                  ),
                  const PopupMenuItem(
                    value: 'invite',
                    child: Row(
                      children: [
                        Icon(Icons.forward_to_inbox_outlined),
                        SizedBox(width: 8),
                        Text('Email portal invite'),
                      ],
                    ),
                  ),
                  PopupMenuItem(
                    value: 'select',
                    child: Row(
                      children: [
                        Icon(Icons.checklist, color: AppTheme.primaryBlue),
                        const SizedBox(width: 8),
                        Text('Select Multiple', style: TextStyle(color: AppTheme.primaryBlue)),
                      ],
                    ),
                  ),
                  if (canDeleteTenant)
                    PopupMenuItem(
                      value: 'delete',
                      child: Row(
                        children: [
                          Icon(Icons.delete, color: AppTheme.error),
                          const SizedBox(width: 8),
                          Text('Delete', style: TextStyle(color: AppTheme.error)),
                        ],
                      ),
                    ),
                ],
              ),
        onTap: _isSelectionMode
            ? () {
                setState(() {
                  if (isSelected) {
                    _selectedTenantIds.remove(tenant.id);
                  } else {
                    _selectedTenantIds.add(tenant.id);
                  }
                });
              }
            : () => context.push(AppRoute.tenantDetail, extra: tenant),
      ),
    );
  }

  /// Records SMS consent against the selected tenants.
  ///
  /// For the operator who collected agreement on paper or in their old system
  /// and has just imported the rent roll: without this they would have to open
  /// each tenant in turn. The dialog states plainly what is being asserted,
  /// because this is the record we would stand behind if a carrier or a tenant
  /// ever asked why we texted them.
  Future<void> _recordSmsConsentForSelected() async {
    final tenantIds = _selectedTenantIds.toList();
    if (tenantIds.isEmpty) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('Record consent for ${tenantIds.length} '
            '${tenantIds.length == 1 ? 'tenant' : 'tenants'}?'),
        content: const Text(
          'Only do this for tenants who have actually agreed to receive text '
          'messages — on a signed agreement, a move-in form, or in writing. '
          'It is dated today and is what we rely on if anyone asks why they '
          'were texted. Tenants with no mobile number on file are skipped.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Record consent'),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted) return;

    var updated = 0;
    var skipped = 0;
    final now = DateTime.now();
    for (final tenantId in tenantIds) {
      try {
        final tenant = await TenantService.getTenantById(_selectedFacilityId, tenantId);
        final digits = (tenant?.phone ?? '').replaceAll(RegExp(r'[^\d]'), '');
        if (digits.length < 10) {
          skipped++;
          continue;
        }
        await TenantService.updateTenant(
          facilityId: _selectedFacilityId,
          tenantId: tenantId,
          // updateTenant clears smsOptOut and its date whenever a consent
          // date is written, so opting in here cannot leave a stale opt-out.
          smsOptInDate: now,
        );
        updated++;
      } catch (_) {
        skipped++;
      }
    }

    if (!mounted) return;
    setState(() {
      _isSelectionMode = false;
      _selectedTenantIds.clear();
    });
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(skipped == 0
            ? 'Consent recorded for $updated '
                '${updated == 1 ? 'tenant' : 'tenants'}'
            : 'Consent recorded for $updated; $skipped skipped for having no '
                'mobile number on file'),
      ),
    );
  }

  /// Bulk form of the portal invite: everyone currently selected.
  Future<void> _inviteSelectedTenants() async {
    final tenants = ref.read(filteredTenantsProvider(_selectedFacilityId)).value ?? const <TenantModel>[];
    final selected = tenants.where((t) => _selectedTenantIds.contains(t.id)).toList();
    if (selected.isEmpty) return;
    await _inviteTenants(selected);
  }

  /// Emails tenants their portal link and access code, minting codes where
  /// missing. One call per facility. Before launch the pre-launch gate holds
  /// the emails and the result says so; that is expected, not a failure.
  Future<void> _inviteTenants(List<TenantModel> tenants) async {
    final withEmail = tenants.where((t) => t.email.trim().isNotEmpty).toList();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tenants.length == 1 ? 'Email portal invite?' : 'Email ${tenants.length} portal invites?'),
        content: Text(
          tenants.length == 1
              ? '${tenants.first.name} will get an email with the portal link and their access code. '
                  'A code is created if they do not have one.'
              : '${withEmail.length} of ${tenants.length} selected tenants have an email on file and will get the '
                  'portal link and their access code. Codes are created where missing.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Send')),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    final byFacility = <String, List<String>>{};
    for (final t in tenants) {
      byFacility.putIfAbsent(t.facilityId, () => []).add(t.id);
    }
    final lines = <String>[];
    var anyFailed = false;
    try {
      for (final entry in byFacility.entries) {
        final summary = await TenantPortalService.sendPortalInvites(
          facilityId: entry.key,
          tenantIds: entry.value,
        );
        lines.add(summary.describe());
        anyFailed = anyFailed || summary.anythingWentWrong;
        ref.invalidate(facilityTenantsProvider(entry.key));
      }
      if (!mounted) return;
      setState(() {
        _isSelectionMode = false;
        _selectedTenantIds.clear();
      });
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(lines.join(' ')),
        backgroundColor: anyFailed ? AppTheme.error : null,
        duration: const Duration(seconds: 8),
      ));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(ErrorMessageHelper.getUserFriendlyMessage(e)), backgroundColor: AppTheme.error),
      );
    }
  }

  Future<void> _archiveTenant(TenantModel tenant) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Archive Tenant'),
        content: Text('Are you sure you want to archive ${tenant.name}?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: FilledButton.styleFrom(
              backgroundColor: AppTheme.error,
              foregroundColor: Colors.white,
            ),
            child: const Text('Archive'),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      final error = await _archive(tenant.facilityId, tenant.id);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(error ?? '${tenant.name} archived successfully'),
            backgroundColor: error == null ? AppTheme.success : AppTheme.error,
            duration: Duration(seconds: error == null ? 4 : 10),
          ),
        );
      }
    }
  }

  /// Archives one tenant. Returns null on success, else a message to show:
  /// archive is refused while the tenant still holds a unit.
  Future<String?> _archive(String facilityId, String tenantId) async {
    try {
      await ref.read(tenantOperationsProvider.notifier).archiveTenant(
        facilityId: facilityId,
        tenantId: tenantId,
      );
      return null;
    } on TenantStillAssignedToUnitException catch (e) {
      return e.message;
    } catch (e) {
      return 'Error archiving tenant: $e';
    }
  }

  /// Delete was refused because the tenant(s) have history. Explains what
  /// they have and offers Archive only for those who hold no unit, because
  /// archiving an occupant silently stops their rent, autopay and lockout.
  Future<void> _showDeleteRefused(
    TenantDeleteRefusedException refusal, {
    required String facilityId,
    String? note,
  }) async {
    if (!mounted) return;
    final archivable = refusal.blocked.where((b) => b.canArchiveInstead).toList();
    final single = refusal.blocked.length == 1;
    final archive = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(single
            ? "Can't delete ${refusal.blocked.single.tenantName}"
            : 'Nothing was deleted'),
        content: SingleChildScrollView(
          child: Text(note == null ? refusal.details : '${refusal.details}\n\n$note'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(archivable.isEmpty ? 'OK' : 'Cancel'),
          ),
          if (archivable.isNotEmpty)
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: Text(single ? 'Archive instead' : 'Archive ${archivable.length}'),
            ),
        ],
      ),
    );
    if (archive != true || !mounted) return;

    final errors = <String>[];
    for (final b in archivable) {
      final error = await _archive(facilityId, b.tenantId);
      if (error != null) errors.add(single ? error : '${b.tenantName}: $error');
    }
    if (!mounted) return;
    final archived = archivable.length - errors.length;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(errors.isEmpty
            ? (single
                ? '${archivable.single.tenantName} archived'
                : '$archived tenant${archived == 1 ? '' : 's'} archived')
            : errors.join('\n')),
        backgroundColor: errors.isEmpty ? AppTheme.success : AppTheme.error,
        duration: Duration(seconds: errors.isEmpty ? 4 : 10),
      ),
    );
  }

  Future<void> _deleteTenant(TenantModel tenant) async {
    final check = await PermissionService.hasPermission(
      permission: PermissionType.deleteTenant,
      facilityId: tenant.facilityId,
    );
    if (!check.hasPermission) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(check.reason ?? 'You do not have permission to delete tenants.'),
            backgroundColor: AppTheme.warning,
          ),
        );
      }
      return;
    }

    if (!mounted) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete Tenant'),
        content: Text(
          'Permanently delete ${tenant.name}? This cannot be undone.\n\n'
          '$_permanentDeleteNote',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Delete', style: TextStyle(color: AppTheme.error)),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      try {
        final deleted = await ref.read(tenantOperationsProvider.notifier).deleteTenant(
          facilityId: tenant.facilityId,
          tenantId: tenant.id,
          confirmUnitsFreed: _confirmUnitsFreed,
        );

        if (deleted && mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('${tenant.name} deleted successfully'),
              backgroundColor: AppTheme.success,
            ),
          );
        }
      } on TenantDeleteRefusedException catch (e) {
        await _showDeleteRefused(e, facilityId: tenant.facilityId);
      } on TenantDeleteCheckFailedException catch (e) {
        _showDeleteFailed(e.message);
      } on CallableFailureException catch (e) {
        _showDeleteFailed(e.message);
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Error deleting tenant: $e'),
              backgroundColor: AppTheme.error,
            ),
          );
        }
      }
    }
  }

  // Shown before every permanent delete. Deliberately no mention of
  // Move-out: it has no entry point in the app, needs a contract, and
  // emails the tenant.
  static const _permanentDeleteNote =
      'Permanent delete is only for tenants entered by mistake: no charges, '
      'payments, invoices, contracts, liens or saved cards. A unit they hold '
      'is unassigned and listed as available; you will see which before '
      'anything is deleted. For someone who has left: unassign their unit, '
      'then Archive. Their history is kept.';

  Future<bool> _confirmUnitsFreed(List<TenantDeletePlan> freeing) =>
      confirmUnitsFreedDialog(context, freeing);

  void _showDeleteFailed(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), backgroundColor: AppTheme.error),
    );
  }

  Future<void> _deleteSelectedTenants() async {
    if (_selectedTenantIds.isEmpty) return;

    final check = await PermissionService.hasPermission(
      permission: PermissionType.deleteTenant,
      facilityId: _selectedFacilityId,
    );
    if (!check.hasPermission) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(check.reason ?? 'You do not have permission to delete tenants.'),
            backgroundColor: AppTheme.warning,
          ),
        );
      }
      return;
    }

    final tenantsAsync = ref.read(filteredTenantsProvider(_selectedFacilityId));
    final tenants = await tenantsAsync.when(
      data: (tenants) => Future.value(tenants),
      loading: () => Future.value(<TenantModel>[]),
      error: (_, __) => Future.value(<TenantModel>[]),
    );
    final selectedTenants = tenants.where((t) => _selectedTenantIds.contains(t.id)).toList();
    final count = _selectedTenantIds.length;
    final tenantIdsToDelete = _selectedTenantIds.toList();

    // All or nothing per call, so a bigger selection is refused up front.
    if (count > TenantService.maxTenantsPerDelete) {
      _showDeleteFailed(TenantDeleteTooManyException(count).message);
      return;
    }

    if (!mounted) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete Tenants'),
        content: SingleChildScrollView(
          child: Text(
            'Permanently delete $count tenant${count == 1 ? '' : 's'}? '
            'This cannot be undone.\n\n'
            '$_permanentDeleteNote\n\n'
            'If any selected tenant has history, nothing is deleted.\n\n'
            'Selected tenants:\n${selectedTenants.take(5).map((t) => '• ${t.name}').join('\n')}'
            '${selectedTenants.length > 5 ? '\n... and ${selectedTenants.length - 5} more' : ''}',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(
              'Delete $count',
              style: const TextStyle(color: AppTheme.error),
            ),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      try {
        final deleted = await ref.read(tenantOperationsProvider.notifier).deleteTenants(
          facilityId: _selectedFacilityId,
          tenantIds: tenantIdsToDelete,
          confirmUnitsFreed: _confirmUnitsFreed,
        );

        if (deleted && mounted) {
          setState(() {
            _selectedTenantIds.clear();
            _isSelectionMode = false;
          });

          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('$count tenant${count == 1 ? '' : 's'} deleted successfully'),
              backgroundColor: AppTheme.success,
            ),
          );
        }
      } on TenantDeleteRefusedException catch (e) {
        if (!mounted) return;
        // Deselect the refused tenants so pressing Delete again removes only
        // the clean ones; the refusal was all or nothing.
        final blockedIds = e.blocked.map((b) => b.tenantId).toSet();
        final remaining = tenantIdsToDelete.where((id) => !blockedIds.contains(id)).length;
        setState(() => _selectedTenantIds.removeAll(blockedIds));
        await _showDeleteRefused(
          e,
          facilityId: _selectedFacilityId,
          note: remaining == 0
              ? null
              : 'They have been taken out of your selection, so pressing Delete '
                  'again removes only the other $remaining (any units those hold '
                  'are named before anything is deleted).',
        );
      } on TenantDeleteCheckFailedException catch (e) {
        _showDeleteFailed(e.message);
      } on TenantDeleteTooManyException catch (e) {
        _showDeleteFailed(e.message);
      } on CallableFailureException catch (e) {
        _showDeleteFailed(e.message);
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Error deleting tenants: $e'),
              backgroundColor: AppTheme.error,
            ),
          );
        }
      }
    }
  }

  Future<void> _showCreateTenantDialog(
    BuildContext context,
    WidgetRef ref,
    bool isMounted,
    String selectedFacilityId,
  ) async {
    if (selectedFacilityId.isEmpty || selectedFacilityId == 'all') {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Please select a specific facility first'),
          backgroundColor: AppTheme.warning,
        ),
      );
      return;
    }

    try {
      // Get facilities for tenant creation
      final authState = ref.read(authStateProvider);
      if (authState.hasValue && authState.value != null) {
        final user = authState.value!;
        final facilitiesAsync = ref.read(userFacilitiesProvider(user.uid));
        final facilities = facilitiesAsync.whenOrNull(data: (d) => d) ?? <FacilityModel>[];
        
        if (facilities.isEmpty) {
          if (isMounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('Please create a facility first'),
                backgroundColor: AppTheme.warning,
              ),
            );
          }
          return;
        }

        // Navigate to tenant creation screen
        if (isMounted) {
          unawaited(context.push(
            AppRoute.legacyScreen,
            extra: TenantCreationScreen(
              facilities: facilities,
              selectedFacilityId: selectedFacilityId,
            ),
          ));
        }
      }
    } catch (e) {
      if (isMounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error: $e'),
            backgroundColor: AppTheme.error,
          ),
        );
      }
    }
  }
}
