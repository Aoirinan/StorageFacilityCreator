import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:go_router/go_router.dart';
import '../providers/facility_provider.dart';
import '../providers/auth_provider.dart';
import '../providers/active_facility_provider.dart';
import '../models/facility_model.dart';
import '../widgets/email_usage_card.dart';
import '../services/facility_creator_account_service.dart';
import '../services/facility_stats_service.dart';
import '../services/superadmin_service.dart';
import '../providers/dashboard_provider.dart';
import '../widgets/modern_page_wrapper.dart';
import '../theme/app_theme.dart';
import '../services/modern_navigation_service.dart';
import 'facility_creation_wizard.dart';
import 'facility_edit_screen.dart';
import 'subscription_test_screen.dart';
import '../router/app_router.dart';
import '../router/app_route.dart';
import '../utils/error_message_helper.dart';
import '../utils/two_factor_helper.dart';

class FacilityManagementScreen extends ConsumerStatefulWidget {
  const FacilityManagementScreen({super.key});

  @override
  ConsumerState<FacilityManagementScreen> createState() => _FacilityManagementScreenState();
}

class _FacilityManagementScreenState extends ConsumerState<FacilityManagementScreen> {
  bool _showArchived = false;
  String? _selectedFacilityId; // null means "All Facilities"
  int _totalFacilityCount = 0; // Total facilities from account

  @override
  void initState() {
    super.initState();
    _loadTotalFacilityCount();
  }

  Future<void> _loadTotalFacilityCount() async {
    try {
      final account = await FacilityCreatorAccountService.getOrCreateAccountForCurrentUser();
      if (mounted) {
        setState(() {
          _totalFacilityCount = account.facilityIds.length;
        });
      }
    } catch (e) {
      if (kDebugMode) {
        print('Error loading facility count: $e');
      }
    }
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
          content: Text('Counts synced. Dashboard and facility cards will show correct occupancy.'),
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

  @override
  Widget build(BuildContext context) {
    final authState = ref.watch(authStateProvider);
    
    return authState.when(
      data: (user) {
        if (user == null) {
          return const Scaffold(
            body: Center(child: Text('Please sign in to manage facilities')),
          );
        }
        
        return _buildFacilityList(user.uid);
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
              const Text('Error loading facilities'),
              const SizedBox(height: 8),
              Text(ErrorMessageHelper.getUserFriendlyMessage(error)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildFacilityList(String ownerUid) {
    final facilitiesAsync = _showArchived 
        ? ref.watch(facilitiesArchivedProvider(ownerUid))
        : ref.watch(facilitiesActiveProvider(ownerUid));

    return facilitiesAsync.when(
      data: (facilities) {
        // Filter facilities if one is selected
        final displayedFacilities = _selectedFacilityId == null
            ? facilities
            : facilities.where((f) => f.id == _selectedFacilityId).toList();
        
        if (displayedFacilities.isEmpty) {
          return Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  Icons.business_outlined,
                  size: 64,
                  color: AppTheme.textTertiary,
                ),
                const SizedBox(height: 16),
                Text(
                  _showArchived ? 'No archived facilities' : 'No facilities found',
                  style: TextStyle(
                    fontSize: 18,
                    color: AppTheme.textSecondary,
                  ),
                ),
                const SizedBox(height: 8),
                if (!_showArchived) ...[
                  Text(
                    'Create your first facility to get started',
                    style: TextStyle(
                      color: AppTheme.textTertiary,
                    ),
                  ),
                  const SizedBox(height: 24),
                  ElevatedButton.icon(
                    onPressed: () => _showCreateFacilityDialog(context),
                    icon: const Icon(Icons.add_business),
                    label: const Text('Create Facility'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppTheme.primaryBlue,
                      foregroundColor: AppTheme.textOnDark,
                      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
                    ),
                  ),
                ],
              ],
            ),
          );
        }

        return Column(
          children: [
            // Header with Create button and facility selector
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: AppTheme.backgroundLight,
                border: Border(
                  bottom: BorderSide(color: AppTheme.borderLight),
                ),
              ),
              child: Row(
                children: [
                  // Facility selector dropdown - show if there are multiple facilities total OR multiple active facilities
                  if (_totalFacilityCount > 1 || facilities.length > 1) ...[
                    Expanded(
                      child: _buildFacilitySelector(facilities),
                    ),
                    const SizedBox(width: 16),
                  ],
                  // Recompute all facility stats (fix ghost occupancy / sync counts)
                  Tooltip(
                    message: 'Recompute occupancy and tenant counts for all facilities',
                    child: TextButton.icon(
                      onPressed: () => _recomputeAllStats(context),
                      icon: const Icon(Icons.refresh, size: 18),
                      label: const Text('Sync counts'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  // Create Facility button
                  ElevatedButton.icon(
                    onPressed: () => _showCreateFacilityDialog(context),
                    icon: const Icon(Icons.add_business),
                    label: const Text('Create Facility'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppTheme.primaryBlue,
                      foregroundColor: AppTheme.textOnDark,
                      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                    ),
                  ),
                ],
              ),
            ),
            // Facilities list
            Expanded(
              child: ListView.builder(
                padding: const EdgeInsets.all(16),
                itemCount: displayedFacilities.length,
                itemBuilder: (context, index) {
                  final facility = displayedFacilities[index];
                  return _buildFacilityCard(facility);
                },
              ),
            ),
          ],
        );
      },
      loading: () => const Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            CircularProgressIndicator(),
            SizedBox(height: 16),
            Text('Loading facilities...'),
          ],
        ),
      ),
      error: (error, stackTrace) {
        // Check if this is a Firestore index building error
        final isIndexBuilding = error.toString().contains('failed-precondition') &&
            error.toString().contains('requires an index');
        
        return Center(
          child: Padding(
            padding: const EdgeInsets.all(24.0),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  isIndexBuilding ? Icons.build : Icons.error,
                  size: 64,
                  color: isIndexBuilding ? AppTheme.warning : AppTheme.error,
                ),
                const SizedBox(height: 16),
                Text(
                  isIndexBuilding 
                      ? 'Building Firestore Index'
                      : 'Error loading facilities',
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 8),
                if (isIndexBuilding) ...[
                  const Text(
                    'Firestore is building an index for facilities queries.\n'
                    'This usually takes 1-2 minutes.',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 14),
                  ),
                  const SizedBox(height: 16),
                  const CircularProgressIndicator(),
                  const SizedBox(height: 16),
                  ElevatedButton.icon(
                    onPressed: () {
                      if (_showArchived) {
                        ref.invalidate(facilitiesArchivedProvider(ownerUid));
                      } else {
                        ref.invalidate(facilitiesActiveProvider(ownerUid));
                      }
                    },
                    icon: const Icon(Icons.refresh),
                    label: const Text('Retry'),
                  ),
                ] else ...[
                  Text(
                    ErrorMessageHelper.getUserFriendlyMessage(error),
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 12, color: AppTheme.textSecondary),
                  ),
                  const SizedBox(height: 16),
                  ElevatedButton.icon(
                    onPressed: () {
                      if (_showArchived) {
                        ref.invalidate(facilitiesArchivedProvider(ownerUid));
                      } else {
                        ref.invalidate(facilitiesActiveProvider(ownerUid));
                      }
                    },
                    icon: const Icon(Icons.refresh),
                    label: const Text('Retry'),
                  ),
                ],
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildFacilitySelector(List<FacilityModel> facilities) {
    final colorScheme = Theme.of(context).colorScheme;
    return Row(
      children: [
        const Icon(Icons.business, color: AppTheme.primaryBlue),
        const SizedBox(width: 12),
        Expanded(
          child: DropdownButtonFormField<String?>(
            value: _selectedFacilityId,
            decoration: InputDecoration(
              labelText: 'Filter by Facility',
              hintText: 'All Facilities',
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
              ),
              contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            ),
            isExpanded: true,
            selectedItemBuilder: (context) => [
              Text(
                'All Facilities',
                style: AppTheme.dropdownItemTextStyle.copyWith(color: colorScheme.onSurface),
                overflow: TextOverflow.ellipsis,
                maxLines: 1,
              ),
              ...facilities.map((f) => Text(
                f.name,
                style: AppTheme.dropdownItemTextStyle.copyWith(color: colorScheme.onSurface),
                overflow: TextOverflow.ellipsis,
                maxLines: 1,
              )),
            ],
            items: [
              DropdownMenuItem<String?>(
                value: null,
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
                return DropdownMenuItem<String?>(
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
            onChanged: (value) {
              setState(() {
                _selectedFacilityId = value;
              });
            },
          ),
        ),
      ],
    );
  }

  Widget _buildFacilityCard(FacilityModel facility) {
    return Card(
      margin: const EdgeInsets.only(bottom: 16),
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: facility.active ? AppTheme.primaryBlue : AppTheme.textTertiary,
          child: Icon(
            Icons.business,
            color: AppTheme.textOnDark,
          ),
        ),
        title: Row(
          children: [
            Expanded(child: Text(facility.name)),
            if (!facility.active)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: AppTheme.textTertiary,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Text(
                  'Archived',
                  style: TextStyle(
                    color: AppTheme.textOnDark,
                    fontSize: 10,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
          ],
        ),
        subtitle: FutureBuilder<({int totalUnits, int occupiedUnits})>(
          future: FacilityStatsService.computeUnitCounts(facility.id),
          builder: (context, snapshot) {
            // Show the actual count of unit documents (live > cached field).
            // `facility.totalUnits` is the user-set capacity max and is not used here.
            final totalUnits =
                snapshot.data?.totalUnits ?? facility.unitDocCount;
            final occupiedUnits = snapshot.data?.occupiedUnits ?? facility.occupiedUnits;
            final totalDisplay = totalUnits > 0 ? totalUnits.toString() : '—';
            
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('$occupiedUnits/$totalDisplay units occupied'),
            if (facility.address != null) Text(facility.address!),
            if (facility.phone != null) Text(facility.phone!),
            if (facility.email != null) Text(facility.email!),
            // Add email usage indicator for active facilities
            if (facility.active) ...[
              const SizedBox(height: 8),
              EmailUsageIndicator(facilityId: facility.id),
            ],
              ],
            );
          },
        ),
        trailing: PopupMenuButton<String>(
          onSelected: (value) async {
            switch (value) {
              case 'edit':
                _showEditFacilityDialog(context, facility);
                break;
              case 'stripe-connect':
                context.go(AppRoute.stripeConnect, extra: facility);
                break;
              case 'archive':
                await _archiveFacility(facility);
                break;
              case 'restore':
                await _restoreFacility(facility);
                break;
              case 'delete':
                await _deleteFacility(facility);
                break;
            }
          },
          itemBuilder: (context) => [
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
              value: 'stripe-connect',
              child: Row(
                children: [
                  Icon(Icons.account_balance_wallet_outlined),
                  SizedBox(width: 8),
                  Text('Stripe Connect'),
                ],
              ),
            ),
            if (facility.active)
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
            if (!facility.active)
              const PopupMenuItem(
                value: 'restore',
                child: Row(
                  children: [
                    Icon(Icons.restore),
                    SizedBox(width: 8),
                    Text('Restore'),
                  ],
                ),
              ),
            const PopupMenuItem(
              value: 'delete',
              child: Row(
                children: [
                  Icon(Icons.delete, color: AppTheme.error),
                  const SizedBox(width: 8),
                  Text('Delete Permanently', style: TextStyle(color: AppTheme.error)),
                ],
              ),
            ),
          ],
        ),
        onTap: () {
          // Set this facility as the active facility (no modal)
          ref.read(activeFacilityIdProvider.notifier).setActiveFacilityId(facility.id);
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text('Selected ${facility.name}'),
                backgroundColor: AppTheme.primaryBlue,
                duration: const Duration(seconds: 2),
              ),
            );
          }
        },
      ),
    );
  }

  Future<void> _archiveFacility(FacilityModel facility) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Archive Facility'),
        content: Text('Are you sure you want to archive ${facility.name}? This will hide it from the main list.'),
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
        await ref.read(facilityOperationsProvider.notifier).softDeleteFacility(facility.id);
        
        // Invalidate both providers to ensure real-time updates
        final authState = ref.read(authStateProvider);
        authState.whenData((user) {
          if (user != null) {
            ref.invalidate(facilitiesActiveProvider(user.uid));
            ref.invalidate(facilitiesArchivedProvider(user.uid));
          }
        });
        
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('${facility.name} archived successfully'),
              backgroundColor: AppTheme.success,
            ),
          );
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Error archiving facility: $e'),
              backgroundColor: AppTheme.error,
            ),
          );
        }
      }
    }
  }

  Future<void> _restoreFacility(FacilityModel facility) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Restore Facility'),
        content: Text('Are you sure you want to restore ${facility.name}?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Restore'),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      try {
        // Restore by calling restoreFacility
        await ref.read(facilityOperationsProvider.notifier).restoreFacility(facility.id);
        
        // Invalidate both providers to ensure real-time updates
        final authState = ref.read(authStateProvider);
        authState.whenData((user) {
          if (user != null) {
            ref.invalidate(facilitiesActiveProvider(user.uid));
            ref.invalidate(facilitiesArchivedProvider(user.uid));
          }
        });
        
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('${facility.name} restored successfully'),
              backgroundColor: AppTheme.success,
            ),
          );
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Error restoring facility: $e'),
              backgroundColor: AppTheme.error,
            ),
          );
        }
      }
    }
  }

  Future<void> _deleteFacility(FacilityModel facility) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => _DeleteConfirmationDialog(facilityName: facility.name),
    );

    if (confirmed != true) return;

    // Require 2FA verification if enabled
    final canProceed = await TwoFactorHelper.require2FA(
      context: context,
      purpose: 'delete_facility',
      actionName: 'delete ${facility.name}',
    );

    if (!canProceed) {
      // User cancelled or verification failed
      return;
    }

    try {
      await ref.read(facilityOperationsProvider.notifier).hardDeleteFacility(facility.id);
      
      // Invalidate both providers to ensure real-time updates
      final authState = ref.read(authStateProvider);
      authState.whenData((user) {
        if (user != null) {
          ref.invalidate(facilitiesActiveProvider(user.uid));
          ref.invalidate(facilitiesArchivedProvider(user.uid));
        }
      });
      
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('${facility.name} deleted permanently'),
            backgroundColor: AppTheme.success,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error deleting facility: $e'),
            backgroundColor: AppTheme.error,
          ),
        );
      }
    }
  }

  Future<void> _showCreateFacilityDialog(BuildContext context) async {
    final currentUser = FirebaseAuth.instance.currentUser;
    if (currentUser == null) return;

    // Superadmins bypass checks
    if (SuperAdminService.isSuperAdmin(currentUser)) {
      context.push(AppRoute.facilityCreate);
      return;
    }

    try {
      final account = await FacilityCreatorAccountService.getOrCreateAccountForCurrentUser();
      final currentFacilityCount = account.facilityIds.length;

      // Check if trial user trying to create 2nd facility
      if (currentFacilityCount >= 1 && account.hasTrial) {
        _showTrialLimitDialog(context);
        return;
      }

      // Check if non-trial user without subscription trying to add facilities
      if (currentFacilityCount >= 1 && !account.hasActiveSubscription) {
        _showSubscriptionRequiredDialog(context, currentFacilityCount);
        return;
      }

      // Allow navigation to facility creation
      context.push(AppRoute.facilityCreate);
    } catch (e) {
      if (kDebugMode) {
        print('⚠️ Error checking account status: $e');
      }
      // On error, allow navigation (will be caught in wizard)
      context.push(AppRoute.facilityCreate);
    }
  }

  void _showTrialLimitDialog(BuildContext context) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.payment, color: AppTheme.warning),
            SizedBox(width: 8),
            Text('Subscription Required'),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Free trial accounts are limited to 1 facility.\n',
              style: TextStyle(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 12),
            const Text(
              'To add a second facility, you need to:',
              style: TextStyle(fontWeight: FontWeight.w500),
            ),
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: AppTheme.primaryBlueLight.withOpacity(0.1),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: AppTheme.primaryBlueLight.withOpacity(0.3)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(Icons.check_circle, color: AppTheme.primaryBlue, size: 20),
                      const SizedBox(width: 8),
                      const Text(
                        'Subscribe to Base Plan',
                        style: TextStyle(fontWeight: FontWeight.w600),
                      ),
                    ],
                  ),
                  const Padding(
                    padding: EdgeInsets.only(left: 28, top: 4),
                    child: Text(
                      '\$75/month (includes first facility)',
                      style: TextStyle(fontSize: 14),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Icon(Icons.add_circle, color: AppTheme.primaryBlue, size: 20),
                      const SizedBox(width: 8),
                      const Text(
                        'Add Extra Facility',
                        style: TextStyle(fontWeight: FontWeight.w600),
                      ),
                    ],
                  ),
                  const Padding(
                    padding: EdgeInsets.only(left: 28, top: 4),
                    child: Text(
                      '\$75/month (for each additional facility)',
                      style: TextStyle(fontSize: 14),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: AppTheme.success.withOpacity(0.1),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: AppTheme.success.withOpacity(0.3)),
              ),
              child: const Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    'Total: ',
                    style: TextStyle(fontSize: 14),
                  ),
                  Text(
                    '\$45/month',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                      color: AppTheme.success,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          ElevatedButton.icon(
            onPressed: () {
              Navigator.of(context).pop();
              context.push(
                AppRoute.subscription,
                extra: const SubscriptionTestScreen(
                    requireSubscriptionChoice: true,
                    message: 'Subscribe to add your second facility. Your subscription will automatically include the base plan (\$75/month) plus the additional facility (\$75/month).',
                ),
              );
            },
            icon: const Icon(Icons.payment),
            style: ElevatedButton.styleFrom(
              backgroundColor: AppTheme.success,
              foregroundColor: AppTheme.textOnDark,
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
            ),
            label: const Text(
              'Subscribe Now',
              style: TextStyle(fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }

  void _showSubscriptionRequiredDialog(BuildContext context, int currentFacilityCount) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.payment, color: AppTheme.warning),
            SizedBox(width: 8),
            Text('Subscription Required'),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'You already have $currentFacilityCount facility(ies).\n',
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 12),
            const Text(
              'To add additional facilities, you need to:',
              style: TextStyle(fontWeight: FontWeight.w500),
            ),
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: AppTheme.primaryBlueLight.withOpacity(0.1),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: AppTheme.primaryBlueLight.withOpacity(0.3)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(Icons.check_circle, color: AppTheme.primaryBlue, size: 20),
                      const SizedBox(width: 8),
                      const Text(
                        'Subscribe to Base Plan',
                        style: TextStyle(fontWeight: FontWeight.w600),
                      ),
                    ],
                  ),
                  const Padding(
                    padding: EdgeInsets.only(left: 28, top: 4),
                    child: Text(
                      '\$75/month (includes first facility)',
                      style: TextStyle(fontSize: 14),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Icon(Icons.add_circle, color: AppTheme.primaryBlue, size: 20),
                      const SizedBox(width: 8),
                      const Text(
                        'Add Extra Facility',
                        style: TextStyle(fontWeight: FontWeight.w600),
                      ),
                    ],
                  ),
                  const Padding(
                    padding: EdgeInsets.only(left: 28, top: 4),
                    child: Text(
                      '\$75/month (for each additional facility)',
                      style: TextStyle(fontSize: 14),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: AppTheme.success.withOpacity(0.1),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: AppTheme.success.withOpacity(0.3)),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Text(
                    'Total: ',
                    style: TextStyle(fontSize: 14),
                  ),
                  Text(
                    '\$${(25 + (20 * (currentFacilityCount + 1 - 1))).toStringAsFixed(0)}/month',
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                      color: AppTheme.success,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          ElevatedButton.icon(
            onPressed: () {
              Navigator.of(context).pop();
              context.push(
                AppRoute.subscription,
                extra: const SubscriptionTestScreen(
                    requireSubscriptionChoice: true,
                    message: 'Subscribe to add additional facilities. Your subscription will automatically include the base plan (\$75/month) plus each additional facility (\$75/month).',
                ),
              );
            },
            icon: const Icon(Icons.payment),
            style: ElevatedButton.styleFrom(
              backgroundColor: AppTheme.success,
              foregroundColor: AppTheme.textOnDark,
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
            ),
            label: const Text(
              'Subscribe Now',
              style: TextStyle(fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }

  void _showEditFacilityDialog(BuildContext context, FacilityModel facility) {
    context.push(AppRoute.legacyScreen, extra: FacilityEditScreen(facility: facility));
  }
}

class _DeleteConfirmationDialog extends StatefulWidget {
  final String facilityName;

  const _DeleteConfirmationDialog({required this.facilityName});

  @override
  State<_DeleteConfirmationDialog> createState() => _DeleteConfirmationDialogState();
}

class _DeleteConfirmationDialogState extends State<_DeleteConfirmationDialog> {
  final TextEditingController _confirmController = TextEditingController();
  bool get _isValid => _confirmController.text.trim() == 'DELETE';

  @override
  void dispose() {
    _confirmController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Delete Facility Permanently'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Are you sure you want to permanently delete ${widget.facilityName}?'),
          const SizedBox(height: 16),
          const Text(
            'This action cannot be undone and will delete:',
            style: TextStyle(fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          const Text('• All tenants and their data'),
          const Text('• All units and their data'),
          const Text('• All payments and contracts'),
          const Text('• All DNR entries and reminders'),
          const SizedBox(height: 16),
          const Text(
            'Type DELETE to confirm:',
            style: TextStyle(fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _confirmController,
            decoration: const InputDecoration(
              border: OutlineInputBorder(),
              hintText: 'Type DELETE here',
            ),
            onChanged: (value) => setState(() {}),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: _isValid ? () => Navigator.of(context).pop(true) : null,
          child: Text('Delete Permanently', style: TextStyle(color: AppTheme.error)),
        ),
      ],
    );
  }
}
