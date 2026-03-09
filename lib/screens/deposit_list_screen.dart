import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import '../models/deposit_model.dart';
import '../models/facility_model.dart';
import '../providers/facility_provider.dart';
import '../providers/auth_provider.dart';
import '../services/facility_creator_account_service.dart';
import '../services/deposit_service.dart';
import '../widgets/modern_page_wrapper.dart';
import '../theme/app_theme.dart';
import '../services/modern_navigation_service.dart';
import '../router/app_router.dart';
import '../router/app_route.dart';
import 'deposit_detail_screen.dart';
import 'deposit_creation_screen.dart';

/// Provider for deposits stream (by facility)
final depositsForFacilityProvider = StreamProvider.family<List<DepositModel>, String>((ref, facilityId) {
  return DepositService.getDepositsForFacilityStream(facilityId).handleError((error, stackTrace) {
    if (kDebugMode) {
      print('❌ Deposits stream error: $error');
    }
  });
});

class DepositListScreen extends ConsumerStatefulWidget {
  const DepositListScreen({super.key});

  @override
  ConsumerState<DepositListScreen> createState() => _DepositListScreenState();
}

class _DepositListScreenState extends ConsumerState<DepositListScreen> {
  String _selectedFacilityId = '';
  DepositStatus? _statusFilter;
  DateTime? _startDate;
  DateTime? _endDate;

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
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text('Account setup error: $accountError'),
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
    return _selectedFacilityId.isEmpty
          ? _buildNoFacilitiesMessage()
          : Column(
              children: [
                _buildFilters(),
                _buildStats(),
                Expanded(
                  child: _buildDepositsList(),
                ),
              ],
            );
  }

  Widget _buildNoFacilitiesMessage() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.business, size: 64, color: AppTheme.textTertiary),
          const SizedBox(height: 16),
          Text(
            'No Facilities',
            style: Theme.of(context).textTheme.headlineSmall?.copyWith(
              color: AppTheme.textSecondary,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Create a facility to manage deposits',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: AppTheme.textTertiary,
            ),
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
        border: Border(bottom: BorderSide(color: AppTheme.borderLight)),
      ),
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
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
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
                });
              }
            },
          );
        },
      ),
    );
  }

  Widget _buildStats() {
    if (_selectedFacilityId.isEmpty) return const SizedBox.shrink();

    final depositsAsync = ref.watch(depositsForFacilityProvider(_selectedFacilityId));

    return depositsAsync.when(
      data: (deposits) {
        final total = deposits.length;
        final pending = deposits.where((d) => d.status == DepositStatus.pending).length;
        final deposited = deposits.where((d) => d.status == DepositStatus.deposited).length;
        final reconciled = deposits.where((d) => d.status == DepositStatus.reconciled).length;
        final totalAmount = deposits.fold(0.0, (sum, d) => sum + d.totalAmount);
        final unreconciledAmount = deposits
            .where((d) => d.status != DepositStatus.reconciled)
            .fold(0.0, (sum, d) => sum + d.totalAmount);

        return Container(
          padding: const EdgeInsets.all(16.0),
          decoration: BoxDecoration(
            color: AppTheme.backgroundLight,
            border: Border(bottom: BorderSide(color: AppTheme.borderLight)),
          ),
          child: Row(
            children: [
              _buildStatCard('Total Deposits', total.toString(), Icons.account_balance),
              const SizedBox(width: 16),
              _buildStatCard('Pending', pending.toString(), Icons.pending, AppTheme.warning),
              const SizedBox(width: 16),
              _buildStatCard('Deposited', deposited.toString(), Icons.check_circle, AppTheme.info),
              const SizedBox(width: 16),
              _buildStatCard('Reconciled', reconciled.toString(), Icons.verified, AppTheme.success),
              const SizedBox(width: 16),
              _buildStatCard('Unreconciled', '\$${unreconciledAmount.toStringAsFixed(2)}', Icons.attach_money, AppTheme.warning),
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

  Widget _buildDepositsList() {
    if (_selectedFacilityId.isEmpty) {
      return const Center(child: Text('Select a facility'));
    }

    final depositsAsync = ref.watch(depositsForFacilityProvider(_selectedFacilityId));

    return depositsAsync.when(
      data: (deposits) {
        var filteredDeposits = deposits;
        
        if (_statusFilter != null) {
          filteredDeposits = filteredDeposits.where((d) => d.status == _statusFilter).toList();
        }
        
        if (_startDate != null) {
          filteredDeposits = filteredDeposits.where((d) => 
            d.depositDate.isAfter(_startDate!) || d.depositDate.isAtSameMomentAs(_startDate!)
          ).toList();
        }
        
        if (_endDate != null) {
          filteredDeposits = filteredDeposits.where((d) => 
            d.depositDate.isBefore(_endDate!) || d.depositDate.isAtSameMomentAs(_endDate!)
          ).toList();
        }

        if (filteredDeposits.isEmpty) {
          return Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.account_balance, size: 64, color: AppTheme.textTertiary),
                const SizedBox(height: 16),
                Text(
                  _statusFilter != null || _startDate != null || _endDate != null
                      ? 'No deposits match your filters'
                      : 'No deposits yet',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    color: AppTheme.textSecondary,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'Create a deposit to track cash and check payments',
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
          itemCount: filteredDeposits.length,
          itemBuilder: (context, index) {
            final deposit = filteredDeposits[index];
            return _buildDepositCard(deposit);
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
              'Error loading deposits',
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
              onPressed: () => ref.invalidate(depositsForFacilityProvider(_selectedFacilityId)),
              child: const Text('Retry'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDepositCard(DepositModel deposit) {
    final statusColor = _getStatusColor(deposit.status);
    final dateFormat = DateFormat('MMM d, yyyy');

    return Card(
      margin: const EdgeInsets.only(bottom: 12.0),
      child: InkWell(
        onTap: () {
          context.push(
            '${AppRoute.deposits}/detail',
            extra: {'deposit': deposit, 'facilityId': _selectedFacilityId},
          );
        },
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Row(
            children: [
              Container(
                width: 4,
                height: 60,
                decoration: BoxDecoration(
                  color: statusColor,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Text(
                          deposit.depositNumber,
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
                            deposit.statusDisplayName,
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
                      '${deposit.methodDisplayName} • ${dateFormat.format(deposit.depositDate)}',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: AppTheme.textSecondary,
                      ),
                    ),
                    if (deposit.paymentIds.isNotEmpty)
                      Text(
                        '${deposit.paymentIds.length} payment(s)',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: AppTheme.textSecondary,
                        ),
                      ),
                  ],
                ),
              ),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    deposit.formattedTotal,
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  if (deposit.overShort != null)
                    Text(
                      deposit.formattedOverShort!,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: deposit.overShort! > 0 ? AppTheme.success : AppTheme.error,
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

  Color _getStatusColor(DepositStatus status) {
    switch (status) {
      case DepositStatus.pending:
        return AppTheme.warning;
      case DepositStatus.deposited:
        return AppTheme.info;
      case DepositStatus.reconciled:
        return AppTheme.success;
      case DepositStatus.cancelled:
        return AppTheme.textSecondary;
    }
  }

  void _showFiltersDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          title: const Text('Filter Deposits'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              DropdownButtonFormField<DepositStatus?>(
                value: _statusFilter,
                decoration: const InputDecoration(labelText: 'Status'),
                items: [
                  const DropdownMenuItem(value: null, child: Text('All Statuses')),
                  ...DepositStatus.values.map((status) => DropdownMenuItem(
                    value: status,
                    child: Text(_getStatusLabel(status)),
                  )),
                ],
                onChanged: (value) => setState(() => _statusFilter = value),
              ),
              const SizedBox(height: 16),
              ListTile(
                title: const Text('Start Date'),
                subtitle: Text(_startDate != null ? DateFormat('MM/dd/yyyy').format(_startDate!) : 'None'),
                trailing: IconButton(
                  icon: const Icon(Icons.calendar_today),
                  onPressed: () async {
                    final date = await showDatePicker(
                      context: context,
                      initialDate: _startDate ?? DateTime.now(),
                      firstDate: DateTime(2000),
                      lastDate: DateTime.now(),
                    );
                    if (date != null) {
                      setState(() => _startDate = date);
                    }
                  },
                ),
              ),
              ListTile(
                title: const Text('End Date'),
                subtitle: Text(_endDate != null ? DateFormat('MM/dd/yyyy').format(_endDate!) : 'None'),
                trailing: IconButton(
                  icon: const Icon(Icons.calendar_today),
                  onPressed: () async {
                    final date = await showDatePicker(
                      context: context,
                      initialDate: _endDate ?? DateTime.now(),
                      firstDate: DateTime(2000),
                      lastDate: DateTime.now(),
                    );
                    if (date != null) {
                      setState(() => _endDate = date);
                    }
                  },
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () {
                setState(() {
                  _statusFilter = null;
                  _startDate = null;
                  _endDate = null;
                });
              },
              child: const Text('Clear'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: () {
                Navigator.pop(context);
                setState(() {});
              },
              child: const Text('Apply'),
            ),
          ],
        ),
      ),
    );
  }

  String _getStatusLabel(DepositStatus status) {
    switch (status) {
      case DepositStatus.pending:
        return 'Pending';
      case DepositStatus.deposited:
        return 'Deposited';
      case DepositStatus.reconciled:
        return 'Reconciled';
      case DepositStatus.cancelled:
        return 'Cancelled';
    }
  }

  void _navigateToCreateDeposit() {
    context.push(
      '${AppRoute.deposits}/create',
      extra: {'facilityId': _selectedFacilityId},
    );
  }
}

