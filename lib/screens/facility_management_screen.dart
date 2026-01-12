import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:go_router/go_router.dart';
import '../providers/facility_provider.dart';
import '../providers/auth_provider.dart';
import '../models/facility_model.dart';
import '../widgets/email_usage_card.dart';
import '../services/facility_creator_account_service.dart';
import '../services/superadmin_service.dart';
import '../widgets/modern_page_wrapper.dart';
import '../theme/app_theme.dart';
import '../services/modern_navigation_service.dart';
import 'facility_creation_wizard.dart';
import 'facility_edit_screen.dart';
import 'subscription_test_screen.dart';
import '../router/app_router.dart';
import '../router/app_route.dart';
import '../utils/error_message_helper.dart';

class FacilityManagementScreen extends ConsumerStatefulWidget {
  const FacilityManagementScreen({super.key});

  @override
  ConsumerState<FacilityManagementScreen> createState() => _FacilityManagementScreenState();
}

class _FacilityManagementScreenState extends ConsumerState<FacilityManagementScreen> {
  bool _showArchived = false;

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
        
        return ModernPageWrapper(
          currentRoute: '/leads',
          title: 'Facility Management',
          onNavigate: (route) {
            ModernNavigationService.navigateToRoute(context, route);
          },
          actions: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'Show Archived',
                  style: TextStyle(
                    color: AppTheme.textSecondary,
                    fontSize: 14,
                  ),
                ),
                const SizedBox(width: 8),
                Switch(
                  value: _showArchived,
                  onChanged: (value) {
                    setState(() {
                      _showArchived = value;
                    });
                  },
                ),
                const SizedBox(width: 16),
              ],
            ),
          ],
          floatingActionButton: FloatingActionButton.extended(
            onPressed: () => _showCreateFacilityDialog(context),
            backgroundColor: AppTheme.primaryBlue,
            foregroundColor: AppTheme.textOnDark,
            icon: const Icon(Icons.add),
            label: const Text('New Facility'),
          ),
          child: _buildFacilityList(user.uid),
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
        if (facilities.isEmpty) {
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
                if (!_showArchived)
                  Text(
                    'Create your first facility to get started',
                    style: TextStyle(
                      color: AppTheme.textTertiary,
                    ),
                  ),
              ],
            ),
          );
        }

        return ListView.builder(
          padding: const EdgeInsets.all(16),
          itemCount: facilities.length,
          itemBuilder: (context, index) {
            final facility = facilities[index];
            return _buildFacilityCard(facility);
          },
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
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('${facility.occupiedUnits}/${facility.totalUnits} units occupied'),
            if (facility.address != null) Text(facility.address!),
            if (facility.phone != null) Text(facility.phone!),
            if (facility.email != null) Text(facility.email!),
            // Add email usage indicator for active facilities
            if (facility.active) ...[
              const SizedBox(height: 8),
              EmailUsageIndicator(facilityId: facility.id),
            ],
          ],
        ),
        trailing: PopupMenuButton<String>(
          onSelected: (value) async {
            switch (value) {
              case 'edit':
                _showEditFacilityDialog(context, facility);
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
          // Navigate to facility details or management
          _showFacilityDetails(context, facility);
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

    if (confirmed == true) {
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

  void _showFacilityDetails(BuildContext context, FacilityModel facility) {
    // Show facility details dialog with ID for now
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(facility.name),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Address: ${facility.address ?? 'N/A'}'),
            Text('Units: ${facility.occupiedUnits}/${facility.totalUnits}'),
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(8),
              color: AppTheme.backgroundLight,
              child: SelectableText(
                'Facility ID: ${facility.id}',
                style: const TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 12,
                ),
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              'Copy this ID to use for email testing',
              style: TextStyle(fontSize: 11, color: AppTheme.textSecondary),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
        ],
      ),
    );
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
