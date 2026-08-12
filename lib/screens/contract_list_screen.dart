import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../models/contract_model.dart';
import '../providers/contract_provider.dart';
import '../providers/auth_provider.dart';
import '../providers/active_facility_provider.dart';
import '../providers/facility_provider.dart';
import '../services/facility_service.dart';
import '../theme/app_theme.dart';
import '../widgets/modern_page_wrapper.dart';
import '../services/modern_navigation_service.dart';
import '../router/app_router.dart';
import '../router/app_route.dart';
import '../utils/error_message_helper.dart';
import 'contract_detail_screen.dart';
import 'contract_creation_screen.dart';
import 'contract_template_management_screen.dart';
import '../services/contract_send_service.dart';
import 'facility_map_editor_screen.dart';

class ContractListScreen extends ConsumerStatefulWidget {
  final String? facilityId;
  
  const ContractListScreen({super.key, this.facilityId});

  @override
  ConsumerState<ContractListScreen> createState() => _ContractListScreenState();
}

const _kAllFacilitiesContracts = '__all__';

class _ContractListScreenState extends ConsumerState<ContractListScreen> {
  final TextEditingController _searchController = TextEditingController();
  String? _selectedFacilityId;
  List<dynamic> _cachedFacilities = [];
  bool _facilitiesLoadComplete = false;

  @override
  void initState() {
    super.initState();
    _selectedFacilityId = widget.facilityId;
    _loadUserFacilities();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _loadUserFacilities() async {
    try {
      final uid = FirebaseAuth.instance.currentUser?.uid;
      final facilities = uid == null
          ? await FacilityService.getUserFacilities()
          : await ref.read(userFacilitiesProvider(uid).future);
      if (!mounted) return;
      setState(() {
        _cachedFacilities = facilities;
        _facilitiesLoadComplete = true;
        if (_selectedFacilityId == null) {
          if (facilities.isNotEmpty) {
            final activeId =
                ref.read(activeFacilityIdProvider).whenOrNull(data: (d) => d);
            _selectedFacilityId =
                (activeId != null && facilities.any((f) => f.id == activeId))
                    ? activeId
                    : _kAllFacilitiesContracts;
          } else {
            // Avoid infinite spinner when user has no facility access yet
            _selectedFacilityId = _kAllFacilitiesContracts;
          }
        }
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _facilitiesLoadComplete = true;
          _cachedFacilities = [];
          _selectedFacilityId ??= _kAllFacilitiesContracts;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error loading facilities: $e'),
            backgroundColor: AppTheme.error,
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final authState = ref.watch(authStateProvider);
    final contractFilter = ref.watch(contractFilterProvider);
    ref.listen(activeFacilityIdProvider, (prev, next) {
      final nextId = next.whenOrNull(data: (d) => d);
      if (nextId != null && _selectedFacilityId != nextId && mounted) {
        setState(() => _selectedFacilityId = nextId);
      }
    });
    return authState.when(
      data: (user) {
        if (user == null) {
          return const Center(child: Text('Please sign in to view contracts'));
        }

        return _buildBody(user.uid);
      },
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (error, stackTrace) => Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.error, size: 64, color: AppTheme.error),
            const SizedBox(height: 16),
            const Text('Error loading contracts'),
            const SizedBox(height: 8),
            Text(ErrorMessageHelper.getUserFriendlyMessage(error)),
          ],
        ),
      ),
    );
  }

  Widget _buildBody(String userId) {
    if (!_facilitiesLoadComplete || _selectedFacilityId == null) {
      return const Center(child: CircularProgressIndicator());
    }

    return Column(
      children: [
        // Title bar with actions (since AppShell doesn't provide page-specific title)
        Builder(
          builder: (context) {
            final cs = Theme.of(context).colorScheme;
            return Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              decoration: BoxDecoration(
                color: cs.surface,
                border: Border(bottom: BorderSide(color: cs.outline)),
              ),
              child: Row(
                children: [
                  Text(
                    'Contracts',
                    style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600, color: cs.onSurface),
                  ),
                  const Spacer(),
                  TextButton.icon(
                    onPressed: _navigateToTemplateManagement,
                    icon: const Icon(Icons.description, size: 20),
                    label: const Text('Templates'),
                  ),
                  const SizedBox(width: 8),
                  ElevatedButton.icon(
                    onPressed: _selectedFacilityId == _kAllFacilitiesContracts ? null : () => _navigateToCreateContract(),
                    icon: const Icon(Icons.add, size: 20),
                    label: const Text('New contract'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: cs.primary,
                      foregroundColor: cs.onPrimary,
                    ),
                  ),
                ],
              ),
            );
          },
        ),
        
        // Facility Selection
        _buildFacilitySelector(),
        
        // Disclaimer
        Builder(
          builder: (context) {
            final cs = Theme.of(context).colorScheme;
            return Container(
              width: double.infinity,
              margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: cs.surfaceContainerHighest,
                border: Border.all(color: cs.outline),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                'Disclaimer: SFC provides document and e-signature tooling only. You are responsible for the documents you upload and use, including any licensing or membership requirements.',
                style: TextStyle(
                  fontSize: 11,
                  color: cs.onSurfaceVariant,
                  fontStyle: FontStyle.italic,
                ),
                textAlign: TextAlign.center,
              ),
            );
          },
        ),
        
        // Search and Filters
        _buildSearchAndFilters(),
        
        // Contracts List
        Expanded(
          child: _buildContractsList(),
        ),
      ],
    );
  }

  Widget _buildFacilitySelector() {
    final facilities = _cachedFacilities;
    if (facilities.isEmpty) {
      if (!_facilitiesLoadComplete) {
        return const Padding(
          padding: EdgeInsets.all(16.0),
          child: Center(
              child: SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2))),
        );
      }
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Text(
          'No facilities to select',
          style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
        ),
      );
    }

    final effectiveValue = (_selectedFacilityId == null ||
            (_selectedFacilityId != _kAllFacilitiesContracts &&
                !facilities.any((f) => f.id == _selectedFacilityId)))
        ? _kAllFacilitiesContracts
        : _selectedFacilityId!;

    return Padding(
      padding: const EdgeInsets.all(16.0),
      child: DropdownButtonFormField<String>(
        value: effectiveValue,
        decoration: const InputDecoration(
          labelText: 'Facility',
          border: OutlineInputBorder(),
          prefixIcon: Icon(Icons.business),
        ),
        selectedItemBuilder: (context) => [
          Text('All Facilities',
              style: AppTheme.dropdownItemTextStyle.copyWith(
                  color: Theme.of(context).colorScheme.onSurface),
              overflow: TextOverflow.ellipsis,
              maxLines: 1),
          ...facilities.map((f) => Text(f.name,
              style: AppTheme.dropdownItemTextStyle.copyWith(
                  color: Theme.of(context).colorScheme.onSurface),
              overflow: TextOverflow.ellipsis,
              maxLines: 1)),
        ],
        items: [
          const DropdownMenuItem<String>(
            value: _kAllFacilitiesContracts,
            child: Text('All Facilities'),
          ),
          ...facilities.map<DropdownMenuItem<String>>((facility) =>
              DropdownMenuItem<String>(value: facility.id, child: Text(facility.name))),
        ],
        onChanged: (value) {
          if (value != null && mounted) {
            setState(() => _selectedFacilityId = value);
            if (value != _kAllFacilitiesContracts) {
              ref.read(activeFacilityIdProvider.notifier).setActiveFacilityId(value);
            }
          }
        },
      ),
    );
  }

  Widget _buildSearchAndFilters() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16.0),
      child: Column(
        children: [
          // Search Bar
          TextField(
            controller: _searchController,
            decoration: InputDecoration(
              hintText: 'Search contracts...',
              prefixIcon: const Icon(Icons.search),
              suffixIcon: _searchController.text.isNotEmpty
                  ? IconButton(
                      icon: const Icon(Icons.clear),
                      onPressed: () {
                        _searchController.clear();
                        ref.read(contractFilterProvider.notifier).updateSearchQuery('');
                      },
                    )
                  : null,
              border: const OutlineInputBorder(),
            ),
            onChanged: (value) {
              ref.read(contractFilterProvider.notifier).updateSearchQuery(value);
            },
          ),
          
          const SizedBox(height: 16),
          
          // Filter Chips
          _buildFilterChips(),
        ],
      ),
    );
  }

  Widget _buildFilterChips() {
    final contractFilter = ref.watch(contractFilterProvider);
    
    return Wrap(
      spacing: 8,
      children: [
        // Status Filter
        FilterChip(
          label: const Text('Status'),
          selected: contractFilter.status != null,
          onSelected: (selected) {
            if (selected) {
              _showStatusFilter();
            } else {
              ref.read(contractFilterProvider.notifier).updateStatus(null);
            }
          },
        ),
        
        // Type Filter
        FilterChip(
          label: const Text('Type'),
          selected: contractFilter.type != null,
          onSelected: (selected) {
            if (selected) {
              _showTypeFilter();
            } else {
              ref.read(contractFilterProvider.notifier).updateType(null);
            }
          },
        ),
        
        // Clear Filters
        if (contractFilter.status != null || contractFilter.type != null)
          FilterChip(
            label: const Text('Clear'),
            selected: false,
            onSelected: (selected) {
              ref.read(contractFilterProvider.notifier).clearFilters();
            },
          ),
      ],
    );
  }

  Widget _buildContractsList() {
    if (_selectedFacilityId == null) {
      return const Center(child: CircularProgressIndicator());
    }

    // All Facilities: merge contracts from every facility
    if (_selectedFacilityId == _kAllFacilitiesContracts) {
      if (_cachedFacilities.isEmpty) {
        final cs = Theme.of(context).colorScheme;
        return Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.business_outlined, size: 64, color: cs.onSurfaceVariant),
                const SizedBox(height: 16),
                Text(
                  'No facilities available',
                  style: Theme.of(context).textTheme.titleMedium,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 8),
                Text(
                  'If you were invited, ensure you completed “Accept invitation” while signed in with the invited email. '
                  'Otherwise ask a facility owner to confirm your access.',
                  style: TextStyle(color: cs.onSurfaceVariant, fontSize: 14),
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          ),
        );
      }
      final allAsync = _cachedFacilities
          .map((f) => ref.watch(contractsProvider(f.id as String)))
          .toList();
      final isLoading = allAsync.any((a) => a is AsyncLoading);
      if (isLoading) return const Center(child: CircularProgressIndicator());
      final hasError = allAsync.any((a) => a is AsyncError);
      if (hasError) {
        return const Center(child: Text('Error loading contracts'));
      }
      final merged = allAsync
          .expand((a) => a.whenOrNull(data: (d) => d) ?? <ContractModel>[])
          .toList();
      return _buildContractsListView(merged);
    }

    return ref.watch(contractsProvider(_selectedFacilityId!)).when(
      data: (contracts) => _buildContractsListView(contracts),
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (error, stackTrace) => Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.error, size: 64, color: AppTheme.error),
            const SizedBox(height: 16),
            const Text('Error loading contracts'),
            const SizedBox(height: 8),
            Text(ErrorMessageHelper.getUserFriendlyMessage(error)),
          ],
        ),
      ),
    );
  }

  Widget _buildContractsListView(List<ContractModel> contracts) {
    final filteredContracts = _filterContracts(contracts);
    if (filteredContracts.isEmpty) {
      final cs = Theme.of(context).colorScheme;
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.description, size: 64, color: cs.onSurfaceVariant),
            const SizedBox(height: 16),
            const Text('No contracts found'),
            const SizedBox(height: 8),
            Text(
              'Create your first contract to get started',
              style: TextStyle(color: cs.onSurfaceVariant),
            ),
          ],
        ),
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.all(16.0),
      itemCount: filteredContracts.length,
      itemBuilder: (context, index) => _buildContractCard(filteredContracts[index]),
    );
  }

  Widget _buildContractCard(ContractModel contract) {
    final cs = Theme.of(context).colorScheme;
    return Card(
      elevation: 0,
      margin: const EdgeInsets.only(bottom: 8.0),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: cs.outline, width: 1),
      ),
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: _getStatusColor(contract.status),
          child: Icon(
            _getStatusIcon(contract.status),
            color: cs.onPrimary,
          ),
        ),
        title: Text(
          contract.title,
          style: const TextStyle(fontWeight: FontWeight.bold),
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(contract.description),
            const SizedBox(height: 4),
            Row(
              children: [
                _buildStatusChip(contract.status),
                const SizedBox(width: 8),
                _buildTypeChip(contract.type),
              ],
            ),
            if (contract.expiresAt != null)
              Text(
                'Expires: ${_formatDate(contract.expiresAt!)}',
                style: TextStyle(
                  color: contract.expiresAt!.isBefore(DateTime.now())
                      ? Theme.of(context).colorScheme.error
                      : Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
          ],
        ),
        trailing: PopupMenuButton<String>(
          onSelected: (value) => _handleContractAction(value, contract),
          itemBuilder: (context) => [
            const PopupMenuItem(
              value: 'view',
              child: Text('View Details'),
            ),
            const PopupMenuItem(
              value: 'edit',
              child: Text('Edit'),
            ),
            if (contract.status == ContractStatus.draft) ...[
              const PopupMenuItem(
                value: 'sign_in_person',
                child: Text('Sign in person'),
              ),
              const PopupMenuItem(
                value: 'send',
                child: Text('Send'),
              ),
            ],
            if (contract.status == ContractStatus.sent) ...[
              const PopupMenuItem(
                value: 'resend',
                child: Text('Resend Contract'),
              ),
              const PopupMenuItem(
                value: 'sign',
                child: Text('Sign'),
              ),
            ],
            const PopupMenuItem(
              value: 'delete',
              child: Text('Delete'),
            ),
          ],
        ),
        onTap: () => _navigateToContractDetail(contract),
      ),
    );
  }

  Widget _buildStatusChip(ContractStatus status) {
    final cs = Theme.of(context).colorScheme;
    return Chip(
      label: Text(
        status.displayName,
        style: TextStyle(fontSize: 12, color: cs.onPrimary),
      ),
      backgroundColor: _getStatusColor(status),
    );
  }

  Widget _buildTypeChip(ContractType type) {
    final cs = Theme.of(context).colorScheme;
    return Chip(
      label: Text(
        type.displayName,
        style: TextStyle(fontSize: 12, color: cs.onSurface),
      ),
      backgroundColor: cs.surfaceContainerHighest,
    );
  }

  Color _getStatusColor(ContractStatus status) {
    final cs = Theme.of(context).colorScheme;
    switch (status) {
      case ContractStatus.draft:
        return cs.onSurfaceVariant;
      case ContractStatus.sent:
        return AppTheme.warning;
      case ContractStatus.signed:
        return AppTheme.success;
      case ContractStatus.expired:
        return cs.error;
      case ContractStatus.cancelled:
        return cs.error;
    }
  }

  IconData _getStatusIcon(ContractStatus status) {
    switch (status) {
      case ContractStatus.draft:
        return Icons.edit;
      case ContractStatus.sent:
        return Icons.send;
      case ContractStatus.signed:
        return Icons.check;
      case ContractStatus.expired:
        return Icons.schedule;
      case ContractStatus.cancelled:
        return Icons.cancel;
    }
  }

  String _formatDate(DateTime date) {
    return '${date.month}/${date.day}/${date.year}';
  }

  List<ContractModel> _filterContracts(List<ContractModel> contracts) {
    final filter = ref.read(contractFilterProvider);
    
    return contracts.where((contract) {
      // Status filter
      if (filter.status != null && contract.status != filter.status) {
        return false;
      }
      
      // Type filter
      if (filter.type != null && contract.type != filter.type) {
        return false;
      }
      
      // Search query filter
      if (filter.searchQuery.isNotEmpty) {
        final query = filter.searchQuery.toLowerCase();
        if (!contract.title.toLowerCase().contains(query) &&
            !contract.description.toLowerCase().contains(query)) {
          return false;
        }
      }
      
      return true;
    }).toList();
  }

  void _showStatusFilter() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Filter by Status'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: ContractStatus.values.map((status) {
            return RadioListTile<ContractStatus>(
              title: Text(status.displayName),
              value: status,
              groupValue: ref.read(contractFilterProvider).status,
              onChanged: (value) {
                ref.read(contractFilterProvider.notifier).updateStatus(value);
                Navigator.of(context).pop();
              },
            );
          }).toList(),
        ),
      ),
    );
  }

  void _showTypeFilter() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Filter by Type'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: ContractType.values.map((type) {
            return RadioListTile<ContractType>(
              title: Text(type.displayName),
              value: type,
              groupValue: ref.read(contractFilterProvider).type,
              onChanged: (value) {
                ref.read(contractFilterProvider.notifier).updateType(value);
                Navigator.of(context).pop();
              },
            );
          }).toList(),
        ),
      ),
    );
  }

  void _navigateToTemplateManagement() {
    final facilityId = _selectedFacilityId ?? '';
    context.push(facilityId.isEmpty ? AppRoute.contractTemplates : '${AppRoute.contractTemplates}?facilityId=$facilityId');
  }

  void _navigateToCreateContract() {
    context.push(
      '${AppRoute.contractCreate}?facilityId=${_selectedFacilityId ?? ''}',
    ).then((_) {
      // Refresh providers when returning from contract creation
      if (_selectedFacilityId != null) {
        ref.invalidate(contractsProvider(_selectedFacilityId!));
      }
    });
  }

  void _navigateToContractDetail(ContractModel contract) {
    context.push(AppRoute.contractDetail, extra: contract).then((_) {
      // Refresh providers when returning from contract detail
      if (_selectedFacilityId != null) {
        ref.invalidate(contractsProvider(_selectedFacilityId!));
      }
    });
  }

  void _handleContractAction(String action, ContractModel contract) {
    switch (action) {
      case 'view':
        _navigateToContractDetail(contract);
        break;
      case 'edit':
        _navigateToContractDetail(contract);
        // Edit functionality is available in the detail screen
        break;
      case 'send':
        _sendContract(contract);
        break;
      case 'sign_in_person':
        _signContractInPerson(contract);
        break;
      case 'resend':
        _navigateToContractDetail(contract);
        break;
      case 'sign':
        _signContract(contract);
        break;
      case 'delete':
        _deleteContract(contract);
        break;
    }
  }

  void _invalidateContractsList(ContractModel contract) {
    ref.invalidate(contractsProvider(contract.facilityId));
  }

  Future<void> _sendContract(ContractModel contract) async {
    final sentBy = ref.read(authStateProvider).value?.uid ?? '';
    await ContractSendService.sendContractForSignature(
      context: context,
      contract: contract,
      sentBy: sentBy,
      onComplete: () => _invalidateContractsList(contract),
    );
  }

  Future<void> _signContractInPerson(ContractModel contract) async {
    final sentBy = ref.read(authStateProvider).value?.uid ?? '';
    final signed = await ContractSendService.signContractInPerson(
      context: context,
      contract: contract,
      sentBy: sentBy,
    );
    if (signed == true && mounted) {
      _invalidateContractsList(contract);
    }
  }

  Future<void> _signContract(ContractModel contract) async {
    final signed = await ContractSendService.openSigningScreenFromContract(
      context,
      contract,
    );
    if (signed == true && mounted) {
      _invalidateContractsList(contract);
    }
  }

  void _deleteContract(ContractModel contract) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete Contract'),
        content: const Text('Are you sure you want to delete this contract?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () {
              Navigator.of(context).pop();
              ref.read(contractOperationsProvider.notifier).deleteContract(contract.facilityId, contract.id).then((_) {
                _invalidateContractsList(contract);
              });
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: AppTheme.error,
              foregroundColor: Colors.white,
            ),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
  }
}
