import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show debugPrint, kIsWeb;
import 'package:go_router/go_router.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:file_picker/file_picker.dart';
import 'package:csv/csv.dart';
import 'dart:convert';
import '../providers/tenant_provider.dart';
import '../providers/auth_provider.dart';
import '../providers/facility_provider.dart';
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
import 'client_detail_screen.dart';
import 'tenant_creation_screen.dart';
import 'tenant_edit_screen.dart';
import 'subscription_test_screen.dart';
import 'facility_map_editor_screen.dart';

class ClientListScreen extends ConsumerStatefulWidget {
  const ClientListScreen({super.key});

  @override
  ConsumerState<ClientListScreen> createState() => _ClientListScreenState();
}

class _ClientListScreenState extends ConsumerState<ClientListScreen> {
  final _searchController = TextEditingController();
  String _selectedFacilityId = '';
  List<FacilityModel> _facilities = [];

  @override
  void initState() {
    super.initState();
    _loadFacilities();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _loadFacilities() async {
    try {
      final authState = ref.read(authStateProvider);
      if (authState.hasValue && authState.value != null) {
        final user = authState.value!;
        
        // Ensure account exists (for free trial users)
        try {
          await FacilityCreatorAccountService.getOrCreateAccountForCurrentUser();
        } catch (accountError) {
          // Account creation is non-critical, log but continue
          if (mounted) {
            debugPrint('⚠️ Could not ensure account exists: $accountError');
          }
        }
        
        // Use cached provider instead of direct service call
        final facilities = await ref.read(userFacilitiesProvider(user.uid).future);
        setState(() {
          _facilities = facilities;
          if (facilities.isNotEmpty) {
            _selectedFacilityId = facilities.first.id;
          }
        });
        
        if (facilities.isEmpty && mounted) {
          // Show helpful message if no facilities
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('No facilities found. Please create a facility first.'),
              backgroundColor: AppTheme.warning,
              duration: Duration(seconds: 4),
            ),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        final errorMessage = e.toString();
        String userMessage;
        
        if (errorMessage.contains('permission-denied')) {
          userMessage = 'Permission denied. Please check your account status or contact support.';
        } else if (errorMessage.contains('Not signed in')) {
          userMessage = 'Please sign in to view your facilities.';
        } else {
          userMessage = 'Error loading facilities: ${e.toString()}';
        }
        
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(userMessage),
            backgroundColor: AppTheme.error,
            duration: const Duration(seconds: 5),
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final authState = ref.watch(authStateProvider);
    final tenantsAsync = ref.watch(filteredTenantsProvider(_selectedFacilityId));

    return authState.when(
      data: (user) {
        if (user == null) {
          return const Scaffold(
            body: Center(child: Text('Please sign in to view tenants')),
          );
        }

        return ModernPageWrapper(
          currentRoute: '/tenants',
          title: 'Client Management',
          onNavigate: (route) {
            ModernNavigationService.navigateToRoute(context, route);
          },
          actions: [
            IconButton(
              onPressed: () => _importTenantsFromCsv(),
              icon: const Icon(Icons.upload_file),
              tooltip: 'Import Tenants from CSV',
            ),
            IconButton(
              onPressed: () {
                if (_facilities.isEmpty) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: const Text('Please create a facility first'),
                      backgroundColor: AppTheme.warning,
                    ),
                  );
                  return;
                }
                
                context.push(
                  AppRoute.legacyScreen,
                  extra: TenantCreationScreen(
                    facilities: _facilities,
                    selectedFacilityId: _selectedFacilityId,
                  ),
                );
              },
              icon: const Icon(Icons.person_add),
              tooltip: 'Add New Tenant',
            ),
          ],
          child: Column(
            children: [
              // Search and Filter Section
              Container(
                padding: const EdgeInsets.all(AppConstants.spacingM),
                color: AppTheme.backgroundLight,
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
                        fillColor: AppTheme.surface,
                      ),
                      onChanged: (value) {
                        ref.read(tenantSearchProvider.notifier).state = value;
                      },
                    ),
                    const SizedBox(height: AppConstants.spacingM),
                    
                    // Facility Filter
                    if (_facilities.isNotEmpty)
                      Row(
                        children: [
                          const Icon(Icons.business, size: 20),
                          const SizedBox(width: AppConstants.spacingS),
                          const Text('Facility: '),
                          const SizedBox(width: AppConstants.spacingS),
                          Expanded(
                            child: DropdownButtonFormField<String>(
                              value: _selectedFacilityId.isEmpty ? null : _selectedFacilityId,
                              decoration: const InputDecoration(
                                border: OutlineInputBorder(),
                                contentPadding: EdgeInsets.symmetric(horizontal: AppConstants.spacingM - 4, vertical: AppConstants.spacingS),
                              ),
                              items: _facilities.map((facility) {
                                return DropdownMenuItem<String>(
                                  value: facility.id,
                                  child: Text(facility.name),
                                );
                              }).toList(),
                              onChanged: (value) {
                                setState(() {
                                  _selectedFacilityId = value ?? '';
                                });
                              },
                            ),
                          ),
                          const SizedBox(width: 8),
                          if (_selectedFacilityId.isNotEmpty)
                            IconButton(
                              onPressed: () => context.push('/units/map?facilityId=$_selectedFacilityId'),
                              icon: const Icon(Icons.map),
                              tooltip: 'View Map',
                              color: AppTheme.primaryBlue,
                            ),
                        ],
                      ),
                  ],
                ),
              ),
              
              // Tenants List
              Expanded(
                child: tenantsAsync.when(
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
                                  : 'No tenants found',
                              style: TextStyle(
                                fontSize: 18,
                                color: AppTheme.textSecondary,
                              ),
                            ),
                            const SizedBox(height: AppConstants.spacingS),
                            if (_searchController.text.isEmpty)
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
                        return _buildTenantCard(tenant);
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
                                  onPressed: () {
                                    ref.invalidate(facilityTenantsProvider(_selectedFacilityId));
                                    _loadFacilities();
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
            ],
          ),
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

  Widget _buildTenantCard(TenantModel tenant) {
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: AppConstants.spacingM, vertical: AppConstants.spacingXS),
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: tenant.isActive 
              ? (tenant.isLate ? AppTheme.error : AppTheme.success) 
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
            if (tenant.isLate && tenant.daysLate > 0)
              Container(
                margin: const EdgeInsets.only(top: AppConstants.spacingXS),
                padding: const EdgeInsets.symmetric(horizontal: AppConstants.spacingS, vertical: AppConstants.spacingXS / 2),
                decoration: BoxDecoration(
                  color: AppTheme.error.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: AppTheme.error.withOpacity(0.3)),
                ),
                child: Text(
                  'LATE PAYMENT - ${tenant.daysLate} ${tenant.daysLate == 1 ? 'day' : 'days'}',
                  style: const TextStyle(
                    color: AppTheme.error,
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
          ],
        ),
        trailing: PopupMenuButton<String>(
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
        onTap: () => context.push(AppRoute.tenantDetail, extra: tenant),
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

  Future<void> _importTenantsFromCsv() async {
    if (_selectedFacilityId.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Please select a facility first'),
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
      final csvData = const CsvToListConverter().convert(csvString);

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
      await _processCsvImport(csvData);
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

  Future<void> _processCsvImport(List<List<dynamic>> csvData) async {
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
            facilityId: _selectedFacilityId,
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
      if (mounted) {
        Navigator.of(context).pop();
      }

      // Show results
      if (mounted) {
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
      ref.invalidate(facilityTenantsProvider(_selectedFacilityId));
    } catch (e) {
      if (mounted) {
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
}
