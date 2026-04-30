import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show debugPrint, kIsWeb;
import 'package:go_router/go_router.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:file_picker/file_picker.dart';
import 'package:csv/csv.dart';
import 'dart:convert';
import '../providers/tenant_provider.dart';
import '../providers/permission_provider.dart';
import '../providers/auth_provider.dart';
import '../providers/facility_provider.dart';
import '../providers/active_facility_provider.dart';
import '../models/tenant_model.dart';
import '../models/facility_model.dart';
import '../services/facility_creator_account_service.dart';
import '../services/tenant_service.dart';
import '../widgets/modern_page_wrapper.dart';
import '../theme/app_theme.dart';
import '../constants/app_constants.dart';
import '../services/modern_navigation_service.dart';
import '../router/app_router.dart';
import '../router/app_route.dart';
import '../widgets/keyboard_scrollable.dart';
import '../utils/error_message_helper.dart';
import '../utils/setup_retry_controller.dart';
import 'client_detail_screen.dart';
import 'tenant_creation_screen.dart';
import 'tenant_edit_screen.dart';
import 'subscription_test_screen.dart';
import 'facility_map_editor_screen.dart';
import 'tenant_csv_import_wizard_screen.dart';
import '../services/late_logic_service.dart';
import '../services/permission_service.dart';
import '../models/permission_model.dart';

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
      final newLocal = activeId == null ? 'all' : activeId;
      if (newLocal == _selectedFacilityId) return;
      if (activeId == null || facilities.any((f) => f.id == activeId)) {
        setState(() {
          _selectedFacilityId = newLocal;
          _hasInitializedFacility = true;
        });
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
                    
                    // Selection Mode Controls
                    if (_isSelectionMode && _selectedFacilityId.isNotEmpty)
                      Container(
                        padding: const EdgeInsets.symmetric(vertical: AppConstants.spacingS),
                        decoration: BoxDecoration(
                          color: cs.primary.withOpacity(0.1),
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
                                            _selectedTenantIds.addAll(tenants.where((t) => t.id != null).map((t) => t.id!));
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
                                        : _selectedFacilityId.isEmpty
                                            ? 'No facility selected'
                                            : 'No tenants found',
                                    style: TextStyle(
                                      fontSize: 18,
                                      color: AppTheme.textSecondary,
                                    ),
                                  ),
                                  const SizedBox(height: AppConstants.spacingS),
                                  if (_searchController.text.isEmpty && _selectedFacilityId.isNotEmpty)
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
    int? gracePeriodDays,
    bool canDeleteTenant = false,
  }) {
    final grace = gracePeriodDays ?? 3;
    final isLate = LateLogicService.isTenantLate(tenant, gracePeriodDays: grace);
    final daysLate = LateLogicService.getTenantDaysLate(tenant, gracePeriodDays: grace);
    final isSelected = _selectedTenantIds.contains(tenant.id);

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: AppConstants.spacingM, vertical: AppConstants.spacingXS),
      color: isSelected ? AppTheme.primaryBlue.withOpacity(0.1) : null,
      child: ListTile(
        leading: _isSelectionMode
            ? Checkbox(
                value: isSelected,
                onChanged: (value) {
                  setState(() {
                    if (value == true) {
                      _selectedTenantIds.add(tenant.id!);
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
            Text('Unit: ${tenant.unitNumber}'),
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
                  color: AppTheme.error.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: AppTheme.error.withOpacity(0.3)),
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
                      context.push(AppRoute.tenantDetail, extra: tenant);
                      break;
                    case 'edit':
                      context.push(
                        AppRoute.legacyScreen,
                        extra: TenantEditScreen(
                          tenant: tenant,
                          facilityIdOverride: _selectedFacilityId.isNotEmpty ? _selectedFacilityId : null,
                        ),
                      );
                      break;
                    case 'archive':
                      await _archiveTenant(tenant);
                      break;
                    case 'select':
                      setState(() {
                        _isSelectionMode = true;
                        _selectedTenantIds.clear();
                        _selectedTenantIds.add(tenant.id!);
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
                    _selectedTenantIds.add(tenant.id!);
                  }
                });
              }
            : () => context.push(AppRoute.tenantDetail, extra: tenant),
      ),
    );
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
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Archive'),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      try {
        await ref.read(tenantOperationsProvider.notifier).archiveTenant(
          facilityId: tenant.facilityId,
          tenantId: tenant.id,
        );
        
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('${tenant.name} archived successfully'),
              backgroundColor: AppTheme.success,
            ),
          );
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Error archiving tenant: $e'),
              backgroundColor: AppTheme.error,
            ),
          );
        }
      }
    }
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

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete Tenant'),
        content: Text('Are you sure you want to permanently delete ${tenant.name}? This action cannot be undone.'),
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
        await ref.read(tenantOperationsProvider.notifier).deleteTenant(
          facilityId: tenant.facilityId,
          tenantId: tenant.id,
        );
        
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('${tenant.name} deleted successfully'),
              backgroundColor: AppTheme.success,
            ),
          );
        }
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
    
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete Tenants'),
        content: Text(
          'Are you sure you want to permanently delete $count tenant${count == 1 ? '' : 's'}?\n\n'
          'This action cannot be undone.\n\n'
          'Selected tenants:\n${selectedTenants.take(5).map((t) => '• ${t.name}').join('\n')}'
          '${selectedTenants.length > 5 ? '\n... and ${selectedTenants.length - 5} more' : ''}',
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
        await ref.read(tenantOperationsProvider.notifier).deleteTenants(
          facilityId: _selectedFacilityId,
          tenantIds: tenantIdsToDelete,
        );
        
        if (mounted) {
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

  Future<void> _importTenantsFromCsv() async {
    if (_selectedFacilityId.isEmpty || _selectedFacilityId == 'all') {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Please select a specific facility first'),
          backgroundColor: AppTheme.warning,
        ),
      );
      return;
    }

    try {
      // Pick CSV file
      FilePickerResult? result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['csv'],
        withData: true,
      );

      if (result == null || result.files.isEmpty) {
        return; // User cancelled
      }

      final file = result.files.first;
      if (file.bytes == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Failed to read CSV file'),
            backgroundColor: AppTheme.error,
          ),
        );
        return;
      }

      // Parse CSV
      final csvString = utf8.decode(file.bytes!);
      final csvData = csv.decode(csvString);

      if (csvData.isEmpty || csvData.length < 2) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('CSV file is empty or invalid'),
            backgroundColor: AppTheme.error,
          ),
        );
        return;
      }

      // Show preview dialog
      final shouldProceed = await _showCsvPreviewDialog(csvData);
      if (shouldProceed != true) return;

      // Process import
      await _processCsvImport(context, ref, mounted, _selectedFacilityId, csvData);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error importing CSV: $e'),
            backgroundColor: AppTheme.error,
          ),
        );
      }
    }
  }

  Future<bool?> _showCsvPreviewDialog(List<List<dynamic>> csvData) async {
    // Expected columns: Name, Email, Phone, Unit Number, Monthly Rate, Notes (optional)
    final headers = csvData[0].map((e) => e.toString().trim()).toList();
    final previewRows = csvData.length > 6 ? csvData.sublist(1, 6) : csvData.sublist(1);

    return showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('CSV Import Preview'),
        content: SizedBox(
          width: double.maxFinite,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'Found ${csvData.length - 1} tenant${csvData.length - 1 == 1 ? '' : 's'} to import',
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 16),
                Text(
                  'Expected columns: Name, Email, Phone, Unit Number, Monthly Rate, Notes (optional)',
                  style: TextStyle(fontSize: 12, color: AppTheme.textSecondary),
                ),
                const SizedBox(height: 8),
                Text(
                  'Detected columns: ${headers.join(", ")}',
                  style: TextStyle(fontSize: 12, color: AppTheme.textSecondary),
                ),
                const SizedBox(height: 16),
                const Text(
                  'Preview (first 5 rows):',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 8),
                ...previewRows.map((row) => Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Text(
                    row.map((e) => e.toString()).join(' | '),
                    style: const TextStyle(fontSize: 11),
                  ),
                )),
                if (csvData.length > 6)
                  Text(
                    '... and ${csvData.length - 6} more',
                    style: TextStyle(fontSize: 11, color: AppTheme.textSecondary),
                  ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Import'),
          ),
        ],
      ),
    );
  }

  Future<void> _processCsvImport(
    BuildContext context,
    WidgetRef ref,
    bool isMounted,
    String facilityId,
    List<List<dynamic>> csvData,
  ) async {
    if (csvData.length < 2) return;

    // Show progress dialog
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => const AlertDialog(
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(),
            SizedBox(height: 16),
            Text('Importing tenants...'),
          ],
        ),
      ),
    );

    int successCount = 0;
    int errorCount = 0;
    final errors = <String>[];

    try {
      // Skip header row
      for (int i = 1; i < csvData.length; i++) {
        final row = csvData[i];
        if (row.length < 5) {
          errorCount++;
          errors.add('Row ${i + 1}: Insufficient columns');
          continue;
        }

        try {
          // Parse row data
          final name = row[0].toString().trim();
          final email = row[1].toString().trim();
          final phone = row[2].toString().trim();
          final unitNumber = row[3].toString().trim();
          final monthlyRateStr = row[4].toString().trim();
          final notes = row.length > 5 ? row[5].toString().trim() : '';

          // Validate required fields
          if (name.isEmpty || email.isEmpty || phone.isEmpty || unitNumber.isEmpty) {
            errorCount++;
            errors.add('Row ${i + 1}: Missing required fields');
            continue;
          }

          // Parse monthly rate
          final monthlyRate = double.tryParse(monthlyRateStr);
          if (monthlyRate == null || monthlyRate < 0) {
            errorCount++;
            errors.add('Row ${i + 1}: Invalid monthly rate');
            continue;
          }

          // Create tenant
          await TenantService.createTenant(
            facilityId: facilityId,
            name: name,
            email: email,
            phone: phone,
            unitNumber: unitNumber,
            monthlyRate: monthlyRate,
            notes: notes.isEmpty ? null : notes,
          );

          successCount++;
        } catch (e) {
          errorCount++;
          errors.add('Row ${i + 1}: $e');
        }
      }

      // Close progress dialog
      if (isMounted) {
        Navigator.of(context).pop();
      }

      // Show results
      if (isMounted) {
        showDialog(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Import Complete'),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Successfully imported: $successCount tenant${successCount == 1 ? '' : 's'}'),
                  if (errorCount > 0) ...[
                    const SizedBox(height: 8),
                    Text(
                      'Errors: $errorCount',
                      style: TextStyle(color: AppTheme.error),
                    ),
                    if (errors.isNotEmpty) ...[
                      const SizedBox(height: 8),
                      const Text('Error details:', style: TextStyle(fontWeight: FontWeight.bold)),
                      ...errors.take(10).map((e) => Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Text(
                          e,
                          style: TextStyle(fontSize: 12, color: AppTheme.error),
                        ),
                      )),
                      if (errors.length > 10)
                        Text(
                          '... and ${errors.length - 10} more errors',
                          style: TextStyle(fontSize: 12, color: AppTheme.error),
                        ),
                    ],
                  ],
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('OK'),
              ),
            ],
          ),
        );
      }

      // Refresh tenant list
      ref.invalidate(facilityTenantsProvider(facilityId));
    } catch (e) {
      if (isMounted) {
        Navigator.of(context).pop(); // Close progress dialog
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error during import: $e'),
            backgroundColor: AppTheme.error,
          ),
        );
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
          context.push(
            AppRoute.legacyScreen,
            extra: TenantCreationScreen(
              facilities: facilities,
              selectedFacilityId: selectedFacilityId,
            ),
          );
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
