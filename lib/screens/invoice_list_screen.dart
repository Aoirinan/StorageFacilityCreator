import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import '../models/invoice_model.dart';
import '../providers/invoice_provider.dart';
import '../providers/auth_provider.dart';
import '../providers/facility_provider.dart';
import '../models/facility_model.dart';
import '../services/facility_creator_account_service.dart';
import '../theme/app_theme.dart';
import '../router/app_route.dart';
import 'invoice_detail_screen.dart';

class InvoiceListScreen extends ConsumerStatefulWidget {
  const InvoiceListScreen({super.key});

  @override
  ConsumerState<InvoiceListScreen> createState() => _InvoiceListScreenState();
}

class _InvoiceListScreenState extends ConsumerState<InvoiceListScreen> {
  String _selectedFacilityId = '';
  String _searchQuery = '';
  InvoiceStatus? _statusFilter;
  String? _selectedTenantId;

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
        
        try {
          await FacilityCreatorAccountService.getOrCreateAccountForCurrentUser();
        } catch (accountError) {
          if (mounted) {
            if (kDebugMode) {
              debugPrint('❌ Could not ensure account exists: $accountError');
            }
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
            return;
          }
        }
        
        await Future.delayed(const Duration(milliseconds: 500));
        
        final facilitiesAsync = await ref.read(userFacilitiesProvider(user.uid).future);
        final facilities = facilitiesAsync as List<FacilityModel>? ?? <FacilityModel>[];
        if (facilities.isNotEmpty) {
          setState(() {
            _selectedFacilityId = facilities.first.id;
          });
        }
      }
    } catch (e) {
      if (mounted) {
        if (kDebugMode) {
          debugPrint('❌ Error loading facilities: $e');
        }
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error loading facilities: $e'),
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
            
            return Column(
              children: [
                _buildFilters(),
                _buildStats(),
                Expanded(
                  child: _buildInvoicesList(),
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
            'No Facilities',
            style: Theme.of(context).textTheme.headlineSmall?.copyWith(
              color: AppTheme.textSecondary,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Create a facility to start managing invoices',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: AppTheme.textTertiary,
            ),
          ),
          const SizedBox(height: 24),
          ElevatedButton.icon(
            onPressed: () => context.go(AppRoute.facilityCreate),
            icon: const Icon(Icons.add),
            label: const Text('Create Facility'),
          ),
        ],
      ),
    );
  }

  Widget _buildFilters() {
    return Container(
      padding: const EdgeInsets.all(16.0),
      decoration: BoxDecoration(
        color: AppTheme.backgroundLight,
        border: Border(
          bottom: BorderSide(color: AppTheme.borderLight),
        ),
      ),
      child: Column(
        children: [
          // Facility selector
          Row(
            children: [
              Expanded(
                child: FutureBuilder<List<FacilityModel>>(
                  future: ref.read(authStateProvider).maybeWhen(
                    data: (user) => user != null
                        ? ref.read(userFacilitiesProvider(user.uid).future)
                        : Future.value(<FacilityModel>[]),
                    orElse: () => Future.value(<FacilityModel>[]),
                  ),
                  builder: (context, snapshot) {
                    final facilities = snapshot.data ?? [];
                    if (facilities.isEmpty) return const SizedBox.shrink();
                    
                    return DropdownButtonFormField<String>(
                      value: _selectedFacilityId.isEmpty ? null : _selectedFacilityId,
                      decoration: InputDecoration(
                        labelText: 'Facility',
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8),
                        ),
                        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                      ),
                      items: facilities.map((facility) {
                        return DropdownMenuItem(
                          value: facility.id,
                          child: Text(facility.name),
                        );
                      }).toList(),
                      onChanged: (value) {
                        if (value != null) {
                          setState(() {
                            _selectedFacilityId = value;
                            _selectedTenantId = null; // Reset tenant filter
                          });
                        }
                      },
                    );
                  },
                ),
              ),
              const SizedBox(width: 16),
              // Search
              Expanded(
                flex: 2,
                child: TextField(
                  decoration: InputDecoration(
                    labelText: 'Search invoices',
                    hintText: 'Invoice number, tenant name...',
                    prefixIcon: const Icon(Icons.search),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                    contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  ),
                  onChanged: (value) {
                    setState(() {
                      _searchQuery = value.toLowerCase();
                    });
                  },
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          // Status filter
          Wrap(
            spacing: 8,
            children: [
              FilterChip(
                label: const Text('All'),
                selected: _statusFilter == null,
                onSelected: (selected) {
                  if (selected) {
                    setState(() {
                      _statusFilter = null;
                    });
                  }
                },
              ),
              ...InvoiceStatus.values.map((status) {
                return FilterChip(
                  label: Text(_getStatusLabel(status)),
                  selected: _statusFilter == status,
                  onSelected: (selected) {
                    setState(() {
                      _statusFilter = selected ? status : null;
                    });
                  },
                );
              }),
            ],
          ),
        ],
      ),
    );
  }

  String _getStatusLabel(InvoiceStatus status) {
    switch (status) {
      case InvoiceStatus.draft:
        return 'Draft';
      case InvoiceStatus.sent:
        return 'Sent';
      case InvoiceStatus.paid:
        return 'Paid';
      case InvoiceStatus.overdue:
        return 'Overdue';
      case InvoiceStatus.voided:
        return 'Voided';
    }
  }

  Color _getStatusColor(InvoiceStatus status) {
    switch (status) {
      case InvoiceStatus.draft:
        return AppTheme.textTertiary;
      case InvoiceStatus.sent:
        return AppTheme.info;
      case InvoiceStatus.paid:
        return AppTheme.success;
      case InvoiceStatus.overdue:
        return AppTheme.error;
      case InvoiceStatus.voided:
        return AppTheme.textSecondary;
    }
  }

  Widget _buildStats() {
    if (_selectedFacilityId.isEmpty) return const SizedBox.shrink();

    final invoicesAsync = ref.watch(invoicesForFacilityProvider(_selectedFacilityId));

    return invoicesAsync.when(
      data: (invoices) {
        final total = invoices.length;
        final paid = invoices.where((i) => i.status == InvoiceStatus.paid).length;
        final overdue = invoices.where((i) => i.isOverdue).length;
        final totalAmount = invoices.fold(0.0, (sum, i) => sum + i.total);
        final unpaidAmount = invoices.where((i) => i.balance > 0).fold(0.0, (sum, i) => sum + i.balance);

        return Container(
          padding: const EdgeInsets.all(16.0),
          decoration: BoxDecoration(
            color: AppTheme.backgroundLight,
            border: Border(
              bottom: BorderSide(color: AppTheme.borderLight),
            ),
          ),
          child: Row(
            children: [
              _buildStatCard('Total Invoices', total.toString(), Icons.receipt),
              const SizedBox(width: 16),
              _buildStatCard('Paid', paid.toString(), Icons.check_circle, AppTheme.success),
              const SizedBox(width: 16),
              _buildStatCard('Overdue', overdue.toString(), Icons.warning, AppTheme.error),
              const SizedBox(width: 16),
              _buildStatCard('Unpaid Amount', '\$${unpaidAmount.toStringAsFixed(2)}', Icons.attach_money, AppTheme.warning),
            ],
          ),
        );
      },
      loading: () => const Padding(
        padding: EdgeInsets.all(16.0),
        child: Center(child: CircularProgressIndicator()),
      ),
      error: (error, stack) => Padding(
        padding: const EdgeInsets.all(16.0),
        child: Text('Error loading stats: $error', style: TextStyle(color: AppTheme.error)),
      ),
    );
  }

  Widget _buildStatCard(String label, String value, IconData icon, [Color? color]) {
    return Expanded(
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(12.0),
          child: Row(
            children: [
              Icon(icon, color: color ?? AppTheme.primaryBlue, size: 24),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      label,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: AppTheme.textSecondary,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      value,
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                        color: color ?? AppTheme.textPrimary,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildInvoicesList() {
    if (_selectedFacilityId.isEmpty) {
      return const Center(child: Text('Select a facility'));
    }

    final invoicesAsync = ref.watch(invoicesForFacilityProvider(_selectedFacilityId));

    return invoicesAsync.when(
      data: (invoices) {
        // Apply filters
        var filteredInvoices = invoices;
        
        if (_statusFilter != null) {
          filteredInvoices = filteredInvoices.where((i) => i.status == _statusFilter).toList();
        }
        
        if (_searchQuery.isNotEmpty) {
          filteredInvoices = filteredInvoices.where((invoice) {
            return invoice.invoiceNumber.toLowerCase().contains(_searchQuery) ||
                   invoice.tenantId.toLowerCase().contains(_searchQuery);
          }).toList();
        }

        if (filteredInvoices.isEmpty) {
          return Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.receipt_long, size: 64, color: AppTheme.textTertiary),
                const SizedBox(height: 16),
                Text(
                  _statusFilter != null || _searchQuery.isNotEmpty
                      ? 'No invoices match your filters'
                      : 'No invoices yet',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    color: AppTheme.textSecondary,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'Generate invoices from ledger entries',
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: AppTheme.textTertiary,
                  ),
                ),
              ],
            ),
          );
        }

        return ListView.builder(
          padding: const EdgeInsets.all(16.0),
          itemCount: filteredInvoices.length,
          itemBuilder: (context, index) {
            final invoice = filteredInvoices[index];
            return _buildInvoiceCard(invoice);
          },
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
              'Error loading invoices',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                color: AppTheme.error,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              error.toString(),
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: AppTheme.textSecondary,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            ElevatedButton(
              onPressed: () => ref.invalidate(invoicesForFacilityProvider(_selectedFacilityId)),
              child: const Text('Retry'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildInvoiceCard(InvoiceModel invoice) {
    final statusColor = _getStatusColor(invoice.status);
    final dateFormat = DateFormat('MMM d, yyyy');

    return Card(
      margin: const EdgeInsets.only(bottom: 12.0),
      child: InkWell(
        onTap: () {
          context.push(
            '${AppRoute.invoices}/detail',
            extra: {'invoice': invoice, 'facilityId': _selectedFacilityId},
          );
        },
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Row(
            children: [
              // Status indicator
              Container(
                width: 4,
                height: 60,
                decoration: BoxDecoration(
                  color: statusColor,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(width: 16),
              // Invoice info
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Text(
                          invoice.invoiceNumber,
                          style: Theme.of(context).textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                          decoration: BoxDecoration(
                            color: statusColor.withOpacity(0.1),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(
                            invoice.statusDisplayName,
                            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: statusColor,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Tenant ID: ${invoice.tenantId}',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: AppTheme.textSecondary,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Due: ${dateFormat.format(invoice.dueDate)}',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: AppTheme.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
              // Amount
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    invoice.formattedTotal,
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  if (invoice.balance > 0)
                    Text(
                      'Balance: ${invoice.formattedBalance}',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: AppTheme.error,
                      ),
                    ),
                  if (invoice.isOverdue)
                    Container(
                      margin: const EdgeInsets.only(top: 4),
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      decoration: BoxDecoration(
                        color: AppTheme.error.withOpacity(0.1),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        '${invoice.daysOverdue} days overdue',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: AppTheme.error,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(width: 8),
              Icon(Icons.chevron_right, color: AppTheme.textTertiary),
            ],
          ),
        ),
      ),
    );
  }
}

