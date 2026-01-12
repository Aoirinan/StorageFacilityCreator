import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show debugPrint, kDebugMode;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../models/payment_model.dart';
import '../providers/payment_provider.dart';
import '../providers/auth_provider.dart';
import '../providers/facility_provider.dart';
import '../models/facility_model.dart';
import '../services/facility_creator_account_service.dart';
import '../widgets/modern_page_wrapper.dart';
import '../theme/app_theme.dart';
import '../constants/app_constants.dart';
import '../services/modern_navigation_service.dart';
import '../router/app_router.dart';
import '../router/app_route.dart';
import '../utils/error_message_helper.dart';
import 'payment_detail_screen.dart';
import 'payment_creation_screen.dart';
import 'facility_creation_wizard.dart';
import 'facility_map_editor_screen.dart';
import 'invoice_list_screen.dart';
import '../utils/error_message_helper.dart';
import '../providers/tenant_provider.dart';
import '../services/tenant_service.dart';
import '../models/tenant_model.dart';
import '../services/statement_service.dart';
import '../services/facility_service.dart';
import 'ledger_screen.dart';

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

  @override
  void initState() {
    super.initState();
    _loadUserFacilities();
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
        
        // Small delay to ensure account is fully created and permissions are set
        await Future.delayed(const Duration(milliseconds: 500));
        
        // Now try to load facilities
        final facilitiesAsync = await ref.read(userFacilitiesProvider(user.uid).future);
        final facilities = facilitiesAsync as List<FacilityModel>? ?? <FacilityModel>[];
        if (facilities.isNotEmpty) {
          setState(() {
            _selectedFacilityId = facilities.first.id;
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
  Widget build(BuildContext context) {
    // Use AsyncValue to properly handle loading state
    final authState = ref.watch(authStateProvider);
    
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
            
            // Auto-select first facility if not selected
            if (_selectedFacilityId.isEmpty && facilities.isNotEmpty) {
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (mounted) {
                  setState(() {
                    _selectedFacilityId = facilities.first.id;
                  });
                }
              });
              return const Center(child: CircularProgressIndicator());
            }
            
            return DefaultTabController(
              length: 3,
              child: Column(
                children: [
                  // Tab bar
                  Container(
                    color: AppTheme.surface,
                    child: TabBar(
                      isScrollable: true,
                      tabs: const [
                        Tab(text: 'Payments'),
                        Tab(text: 'Invoices'),
                        Tab(text: 'Statements'),
                      ],
                    ),
                  ),
                  // Tab content
                  Expanded(
                    child: TabBarView(
                      children: [
                        // Payments tab
                        Column(
                          children: [
                            _buildFilters(),
                            _buildStats(),
                            Expanded(
                              child: _buildPaymentsList(),
                            ),
                          ],
                        ),
                        // Invoices tab
                        _buildInvoicesTab(),
                        // Statements tab
                        _buildStatementsTab(),
                      ],
                    ),
                  ),
                ],
              ),
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
  
  Widget _buildInvoicesTab() {
    if (_selectedFacilityId.isEmpty) {
      return _buildNoFacilitiesMessage();
    }
    
    // Use the existing InvoiceListScreen but embed it in this tab
    return const InvoiceListScreen();
  }
  
  Widget _buildStatementsTab() {
    if (_selectedFacilityId.isEmpty) {
      return _buildNoFacilitiesMessage();
    }
    
    return Consumer(
      builder: (context, ref, child) {
        final tenantsAsync = ref.watch(facilityTenantsProvider(_selectedFacilityId));
        
        return tenantsAsync.when(
          data: (tenants) {
            if (tenants.isEmpty) {
              return Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.people_outline, size: 64, color: AppTheme.textTertiary),
                    const SizedBox(height: AppConstants.spacingM),
                    Text(
                      'No Tenants Found',
                      style: Theme.of(context).textTheme.headlineSmall,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Add tenants to generate statements',
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                  ],
                ),
              );
            }
            
            return ListView.builder(
              padding: const EdgeInsets.all(16),
              itemCount: tenants.length,
              itemBuilder: (context, index) {
                final tenant = tenants[index];
                return Card(
                  margin: const EdgeInsets.only(bottom: 8),
                  child: ListTile(
                    leading: CircleAvatar(
                      backgroundColor: AppTheme.primaryBlue.withOpacity(0.1),
                      child: Icon(Icons.person, color: AppTheme.primaryBlue),
                    ),
                    title: Text(tenant.name),
                    subtitle: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (tenant.unitNumber.isNotEmpty)
                          Text('Unit: ${tenant.unitNumber}'),
                        Text(tenant.email),
                      ],
                    ),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          icon: const Icon(Icons.description),
                          tooltip: 'View Ledger & Generate Statement',
                          onPressed: () {
                            context.push(
                              '/tenants/${tenant.id}/ledger?facilityId=${tenant.facilityId}',
                              extra: tenant,
                            );
                          },
                        ),
                      ],
                    ),
                    onTap: () {
                      context.push(
                        '/tenants/${tenant.id}/ledger?facilityId=${tenant.facilityId}',
                        extra: tenant,
                      );
                    },
                  ),
                );
              },
            );
          },
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (error, stackTrace) => Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.error, size: 64, color: AppTheme.error),
                const SizedBox(height: AppConstants.spacingM),
                Text(
                  'Error loading tenants',
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
                const SizedBox(height: 8),
                Text(
                  ErrorMessageHelper.getUserFriendlyMessage(error),
                  style: Theme.of(context).textTheme.bodyMedium,
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          ),
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
                              decoration: const InputDecoration(
                                labelText: 'Facility',
                                border: OutlineInputBorder(),
                              ),
                              items: facilities.map((facility) {
                                return DropdownMenuItem(
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
          Row(
            children: [
              Expanded(
                child: TextField(
                  decoration: const InputDecoration(
                    labelText: 'Search payments',
                    prefixIcon: Icon(Icons.search),
                    border: OutlineInputBorder(),
                  ),
                  onChanged: (value) {
                    setState(() {
                      _searchQuery = value;
                    });
                  },
                ),
              ),
              const SizedBox(width: 16),
              DropdownButton<PaymentStatus?>(
                value: _statusFilter,
                hint: const Text('Status'),
                items: [
                  const DropdownMenuItem(
                    value: null,
                    child: Text('All Status'),
                  ),
                  ...PaymentStatus.values.map((status) {
                    return DropdownMenuItem(
                      value: status,
                      child: Text(status.displayName),
                    );
                  }),
                ],
                onChanged: (value) {
                  setState(() {
                    _statusFilter = value;
                  });
                },
              ),
                                const SizedBox(width: AppConstants.spacingS),
              DropdownButton<PaymentMethod?>(
                value: _methodFilter,
                hint: const Text('Method'),
                items: [
                  const DropdownMenuItem(
                    value: null,
                    child: Text('All Methods'),
                  ),
                  ...PaymentMethod.values.map((method) {
                    return DropdownMenuItem(
                      value: method,
                      child: Text(method.displayName),
                    );
                  }),
                ],
                onChanged: (value) {
                  setState(() {
                    _methodFilter = value;
                  });
                },
              ),
            ],
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
            final stats = ref.watch(paymentStatsProvider(_selectedFacilityId));
            
            return stats.when(
              data: (statsData) => Container(
                padding: const EdgeInsets.all(16),
                child: Row(
                  children: [
                    Expanded(
                      child: _buildStatCard(
                        'Total',
                        '\$${statsData['total']?.toString() ?? '0'}',
                        AppTheme.primaryBlue,
                        statsData['total'] ?? 0,
                      ),
                    ),
                                const SizedBox(width: AppConstants.spacingS),
                    Expanded(
                      child: _buildStatCard(
                        'Paid',
                        '\$${statsData['paid']?.toString() ?? '0'}',
                        AppTheme.success,
                        statsData['paid'] ?? 0,
                      ),
                    ),
                                const SizedBox(width: AppConstants.spacingS),
                    Expanded(
                      child: _buildStatCard(
                        'Pending',
                        '\$${statsData['pending']?.toString() ?? '0'}',
                        AppTheme.warning,
                        statsData['pending'] ?? 0,
                      ),
                    ),
                                const SizedBox(width: AppConstants.spacingS),
                    Expanded(
                      child: _buildStatCard(
                        'Overdue',
                        '\$${statsData['overdue']?.toString() ?? '0'}',
                        AppTheme.error,
                        statsData['overdue'] ?? 0,
                      ),
                    ),
                  ],
                ),
              ),
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (_, __) => const Center(child: Text('Error loading stats')),
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
        return ref.watch(paymentListProvider(_selectedFacilityId)).when(
          data: (payments) {
            // Apply filters
            final filteredPayments = payments.where((payment) {
              // Status filter
              if (_statusFilter != null && payment.status != _statusFilter) {
                return false;
              }
              
              // Method filter
              if (_methodFilter != null && payment.method != _methodFilter) {
                return false;
              }
              
              // Search filter
              if (_searchQuery.isNotEmpty) {
                final query = _searchQuery.toLowerCase();
                final amount = payment.formattedAmount.toLowerCase();
                final notes = payment.notes?.toLowerCase() ?? '';
                final tenantId = payment.tenantId.toLowerCase();
                
                if (!amount.contains(query) && 
                    !notes.contains(query) && 
                    !tenantId.contains(query)) {
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
                return _buildPaymentCard(payment);
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

  Widget _buildPaymentCard(PaymentModel payment) {
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
            Text('Due: ${_formatDate(payment.dueDate)}'),
            if (payment.isOverdue)
              Text(
                'Overdue by ${payment.daysOverdue} days',
                style: TextStyle(color: AppTheme.error),
              ),
            Text('Method: ${payment.methodDisplayName}'),
            if (payment.notes != null)
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
              await ref.read(paymentOperationsProvider.notifier).processPayment(
                facilityId: _selectedFacilityId,
                paymentId: payment.id,
                method: payment.method,
              );
              // Refresh providers after processing payment
              ref.invalidate(paymentListProvider(_selectedFacilityId));
              ref.invalidate(paymentStatsProvider(_selectedFacilityId));
            },
            child: const Text('Process'),
          ),
        ],
      ),
    );
  }
}
