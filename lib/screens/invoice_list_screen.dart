import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import '../models/invoice_model.dart';
import '../providers/invoice_provider.dart';
import '../providers/late_logic_provider.dart';
import '../providers/auth_provider.dart';
import '../providers/facility_provider.dart';
import '../providers/active_facility_provider.dart';
import '../models/facility_model.dart';
import '../services/facility_creator_account_service.dart';
import '../theme/app_theme.dart';
import '../router/app_route.dart';
import '../utils/breakpoints.dart';
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
          final activeId = ref.read(activeFacilityIdProvider).whenOrNull(data: (d) => d);
          final id = (activeId != null && facilities.any((f) => f.id == activeId))
              ? activeId
              : facilities.first.id;
          setState(() => _selectedFacilityId = id);
          // Force fresh invoice list when opening Billing (fixes invoices not showing after create)
          ref.invalidate(invoicesForFacilityProvider(id));
          ref.invalidate(overdueInvoicesProvider(id));
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
    
    ref.listen(activeFacilityIdProvider, (prev, next) {
      final nextId = next.whenOrNull(data: (d) => d);
      if (nextId != null && _selectedFacilityId != nextId && mounted) {
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
    final cs = Theme.of(context).colorScheme;
    final width = MediaQuery.of(context).size.width;
    final isPhone = width < Breakpoints.xs;
    final pad = isPhone ? 12.0 : 16.0;
    return Container(
      padding: EdgeInsets.all(pad),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest,
        border: Border(
          bottom: BorderSide(color: cs.outline),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (isPhone) ...[
            FutureBuilder<List<FacilityModel>>(
              future: ref.read(authStateProvider).maybeWhen(
                data: (user) => user != null
                    ? ref.read(userFacilitiesProvider(user.uid).future)
                    : Future.value(<FacilityModel>[]),
                orElse: () => Future.value(<FacilityModel>[]),
              ),
              builder: (context, snapshot) {
                final facilities = snapshot.data ?? [];
                if (facilities.isEmpty) return const SizedBox.shrink();
                return _buildFacilityDropdown(facilities, true);
              },
            ),
            SizedBox(height: pad),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    decoration: InputDecoration(
                      labelText: 'Search',
                      hintText: 'Invoice #, tenant...',
                      prefixIcon: const Icon(Icons.search, size: 20),
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                      isDense: true,
                    ),
                    onChanged: (value) => setState(() => _searchQuery = value.toLowerCase()),
                  ),
                ),
                if (_selectedFacilityId.isNotEmpty) ...[
                  const SizedBox(width: 8),
                  IconButton(
                    onPressed: () {
                      ref.invalidate(invoicesForFacilityProvider(_selectedFacilityId));
                      ref.invalidate(overdueInvoicesProvider(_selectedFacilityId));
                      if (mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text('Invoices refreshed'),
                            duration: Duration(seconds: 2),
                          ),
                        );
                      }
                    },
                    icon: const Icon(Icons.refresh),
                    tooltip: 'Sync invoices',
                  ),
                ],
              ],
            ),
          ] else
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
                      return _buildFacilityDropdown(facilities, false);
                    },
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  flex: 2,
                  child: TextField(
                    decoration: InputDecoration(
                      labelText: 'Search invoices',
                      hintText: 'Invoice number, tenant name...',
                      prefixIcon: const Icon(Icons.search),
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    ),
                    onChanged: (value) =>
                        setState(() => _searchQuery = value.toLowerCase()),
                  ),
                ),
                if (_selectedFacilityId.isNotEmpty) ...[
                  const SizedBox(width: 8),
                  IconButton(
                    onPressed: () {
                      ref.invalidate(invoicesForFacilityProvider(_selectedFacilityId));
                      ref.invalidate(overdueInvoicesProvider(_selectedFacilityId));
                      if (mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text('Invoices refreshed'),
                            duration: Duration(seconds: 2),
                          ),
                        );
                      }
                    },
                    icon: const Icon(Icons.refresh),
                    tooltip: 'Sync invoices',
                  ),
                ],
              ],
            ),
          SizedBox(height: isPhone ? 10 : 12),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              FilterChip(
                label: Text('All', style: TextStyle(fontSize: isPhone ? 12 : null)),
                selected: _statusFilter == null,
                onSelected: (selected) {
                  if (selected) setState(() => _statusFilter = null);
                },
              ),
              ...InvoiceStatus.values.map((status) {
                return FilterChip(
                  label: Text(_getStatusLabel(status), style: TextStyle(fontSize: isPhone ? 12 : null)),
                  selected: _statusFilter == status,
                  onSelected: (selected) {
                    setState(() => _statusFilter = selected ? status : null);
                  },
                );
              }),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildFacilityDropdown(List<FacilityModel> facilities, bool isDense) {
    final colorScheme = Theme.of(context).colorScheme;
    final textStyle = AppTheme.dropdownItemTextStyle.copyWith(
      fontSize: isDense ? 14 : 16,
      color: colorScheme.onSurface,
    );
    return DropdownButtonFormField<String>(
      value: _selectedFacilityId.isEmpty ? null : _selectedFacilityId,
      isExpanded: true,
      decoration: InputDecoration(
        labelText: 'Facility',
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
        contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: isDense ? 10 : 8),
        isDense: isDense,
      ),
      menuMaxHeight: 300,
      selectedItemBuilder: (context) => facilities.map((f) => Text(
        f.name,
        style: textStyle,
        overflow: TextOverflow.ellipsis,
        maxLines: 1,
      )).toList(),
      items: facilities.map((facility) {
        return DropdownMenuItem(
          value: facility.id,
          child: Text(
            facility.name,
            overflow: TextOverflow.ellipsis,
            style: AppTheme.dropdownItemTextStyle.copyWith(fontSize: isDense ? 14 : 16),
          ),
        );
      }).toList(),
      onChanged: (value) {
        if (value != null) {
          setState(() {
            _selectedFacilityId = value;
            _selectedTenantId = null;
          });
          ref.read(activeFacilityIdProvider.notifier).setActiveFacilityId(value);
          ref.invalidate(invoicesForFacilityProvider(value));
          ref.invalidate(overdueInvoicesProvider(value));
        }
      },
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
        // Include tenant-based overdue (from Delinquency) so Billing aligns when no invoices exist
        final tenantsOverdueAsync = ref.watch(tenantsWithOverdueProvider(_selectedFacilityId));
        final overdueInvoices = invoices.where((i) => i.isOverdue).length;
        final overdueTenants = tenantsOverdueAsync.whenOrNull(data: (d) => d)?.length ?? 0;
        final overdue = overdueInvoices > overdueTenants ? overdueInvoices : overdueTenants;

        final total = invoices.length;
        final paid = invoices.where((i) => i.status == InvoiceStatus.paid).length;
        final totalAmount = invoices.fold(0.0, (sum, i) => sum + i.total);
        final unpaidAmount = invoices.where((i) => i.balance > 0).fold(0.0, (sum, i) => sum + i.balance);

        final isPhone = MediaQuery.of(context).size.width < Breakpoints.xs;
        return Container(
          padding: EdgeInsets.all(isPhone ? 12 : 16),
          decoration: BoxDecoration(
            color: AppTheme.backgroundLight,
            border: Border(
              bottom: BorderSide(color: AppTheme.borderLight),
            ),
          ),
          child: isPhone
              ? Column(
                  children: [
                    Row(
                      children: [
                        Expanded(child: _buildStatCard('Total', total.toString(), Icons.receipt)),
                        const SizedBox(width: 6),
                        Expanded(child: _buildStatCard('Paid', paid.toString(), Icons.check_circle, AppTheme.success)),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        Expanded(child: _buildStatCard('Overdue', overdue.toString(), Icons.warning, AppTheme.error)),
                        const SizedBox(width: 6),
                        Expanded(child: _buildStatCard('Unpaid', '\$${unpaidAmount.toStringAsFixed(2)}', Icons.attach_money, AppTheme.warning)),
                      ],
                    ),
                  ],
                )
              : Row(
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
    final isPhone = MediaQuery.of(context).size.width < Breakpoints.xs;
    return Expanded(
      child: Card(
        child: Padding(
          padding: EdgeInsets.all(isPhone ? 8 : 12),
          child: Row(
            children: [
              Icon(icon, color: color ?? AppTheme.primaryBlue, size: isPhone ? 20 : 24),
              SizedBox(width: isPhone ? 8 : 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      label,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: AppTheme.textSecondary,
                        fontSize: isPhone ? 11 : null,
                      ),
                      overflow: TextOverflow.ellipsis,
                      maxLines: 1,
                    ),
                    SizedBox(height: isPhone ? 2 : 4),
                    Text(
                      value,
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                        color: color ?? AppTheme.textPrimary,
                        fontSize: isPhone ? 14 : null,
                      ),
                      overflow: TextOverflow.ellipsis,
                      maxLines: 1,
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
            child: Padding(
              padding: const EdgeInsets.all(24.0),
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
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Generate invoices from ledger entries: open a tenant → View Ledger → Generate Invoice.',
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: AppTheme.textTertiary,
                    ),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'If you just created an invoice, confirm the Facility dropdown above is set to the same facility, then tap Sync.',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: AppTheme.textTertiary,
                      fontStyle: FontStyle.italic,
                    ),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 24),
                  FilledButton.icon(
                    onPressed: () => context.go(AppRoute.tenants),
                    icon: const Icon(Icons.people),
                    label: const Text('Go to Tenants'),
                    style: FilledButton.styleFrom(
                      backgroundColor: AppTheme.primaryBlue,
                      foregroundColor: AppTheme.textOnDark,
                      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                    ),
                  ),
                ],
              ),
            ),
          );
        }

        final isPhone = MediaQuery.of(context).size.width < Breakpoints.xs;
        return ListView.builder(
          padding: EdgeInsets.all(isPhone ? 12 : 16),
          itemCount: filteredInvoices.length,
          itemBuilder: (context, index) {
            final invoice = filteredInvoices[index];
            return _buildInvoiceCard(invoice, isPhone);
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

  Widget _buildInvoiceCard(InvoiceModel invoice, bool isPhone) {
    final statusColor = _getStatusColor(invoice.status);
    final dateFormat = DateFormat('MMM d, yyyy');
    final pad = isPhone ? 12.0 : 16.0;
    final bodySize = isPhone ? 12.0 : null;

    return Card(
      margin: EdgeInsets.only(bottom: isPhone ? 8 : 12),
      child: InkWell(
        onTap: () {
          context.push(
            '${AppRoute.invoices}/detail',
            extra: {'invoice': invoice, 'facilityId': _selectedFacilityId},
          );
        },
        child: Padding(
          padding: EdgeInsets.all(pad),
          child: isPhone
              ? Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Container(
                          width: 4,
                          height: 48,
                          decoration: BoxDecoration(
                            color: statusColor,
                            borderRadius: BorderRadius.circular(2),
                          ),
                        ),
                        SizedBox(width: pad),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                invoice.invoiceNumber,
                                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                                  fontWeight: FontWeight.bold,
                                  fontSize: 15,
                                ),
                                overflow: TextOverflow.ellipsis,
                              ),
                              Text(
                                invoice.statusDisplayName,
                                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                  color: statusColor,
                                  fontWeight: FontWeight.w500,
                                  fontSize: bodySize,
                                ),
                              ),
                            ],
                          ),
                        ),
                        Icon(Icons.chevron_right, color: AppTheme.textTertiary, size: 20),
                      ],
                    ),
                    SizedBox(height: 8),
                    Text(
                      'Tenant: ${invoice.tenantId}',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: AppTheme.textSecondary,
                        fontSize: bodySize,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                    Text(
                      'Due: ${dateFormat.format(invoice.dueDate)}',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: AppTheme.textSecondary,
                        fontSize: bodySize,
                      ),
                    ),
                    SizedBox(height: 6),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          invoice.formattedTotal,
                          style: Theme.of(context).textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.bold,
                            fontSize: 16,
                          ),
                        ),
                        if (invoice.balance > 0)
                          Text(
                            'Bal: ${invoice.formattedBalance}',
                            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: AppTheme.error,
                              fontSize: bodySize,
                            ),
                          ),
                      ],
                    ),
                    if (invoice.isOverdue)
                      Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: Text(
                          '${invoice.daysOverdue} days overdue',
                          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: AppTheme.error,
                            fontWeight: FontWeight.w500,
                            fontSize: bodySize,
                          ),
                        ),
                      ),
                  ],
                )
              : Row(
                  children: [
                    Container(
                      width: 4,
                      height: 60,
                      decoration: BoxDecoration(
                        color: statusColor,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                    SizedBox(width: pad),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Flexible(
                                child: Text(
                                  invoice.invoiceNumber,
                                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                                    fontWeight: FontWeight.bold,
                                  ),
                                  overflow: TextOverflow.ellipsis,
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
                                  overflow: TextOverflow.ellipsis,
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
                            overflow: TextOverflow.ellipsis,
                          ),
                          const SizedBox(height: 4),
                          Text(
                            'Due: ${dateFormat.format(invoice.dueDate)}',
                            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: AppTheme.textSecondary,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ),
                    ),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Text(
                          invoice.formattedTotal,
                          style: Theme.of(context).textTheme.titleLarge?.copyWith(
                            fontWeight: FontWeight.bold,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                        if (invoice.balance > 0)
                          Text(
                            'Balance: ${invoice.formattedBalance}',
                            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: AppTheme.error,
                            ),
                            overflow: TextOverflow.ellipsis,
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
                              overflow: TextOverflow.ellipsis,
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

