import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:go_router/go_router.dart';
import '../models/contract_model.dart';
import '../providers/contract_provider.dart';
import '../providers/auth_provider.dart';
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
import 'contract_signing_screen.dart';
import 'facility_map_editor_screen.dart';

class ContractListScreen extends ConsumerStatefulWidget {
  final String? facilityId;
  
  const ContractListScreen({super.key, this.facilityId});

  @override
  ConsumerState<ContractListScreen> createState() => _ContractListScreenState();
}

class _ContractListScreenState extends ConsumerState<ContractListScreen> {
  final TextEditingController _searchController = TextEditingController();
  String? _selectedFacilityId;

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
    if (_selectedFacilityId == null) {
      try {
        final facilities = await FacilityService.getUserFacilities();
        if (facilities.isNotEmpty) {
          setState(() {
            _selectedFacilityId = facilities.first.id;
          });
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Error loading facilities: $e'),
              backgroundColor: AppTheme.error,
            ),
          );
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final authState = ref.watch(authStateProvider);
    final contractFilter = ref.watch(contractFilterProvider);

    return authState.when(
      data: (user) {
        if (user == null) {
          return const Scaffold(
            body: Center(child: Text('Please sign in to view contracts')),
          );
        }

        return ModernPageWrapper(
          currentRoute: '/contracts',
          title: 'Contracts',
          onNavigate: (route) {
            ModernNavigationService.navigateToRoute(context, route);
          },
          actions: [
            IconButton(
              icon: const Icon(Icons.description),
              onPressed: () => _navigateToTemplateManagement(),
              tooltip: 'Manage Templates',
            ),
            IconButton(
              icon: const Icon(Icons.add),
              onPressed: () => _navigateToCreateContract(),
              tooltip: 'Create Contract',
            ),
            PopupMenuButton<String>(
              onSelected: (value) {
                switch (value) {
                  case 'clear_filters':
                    ref.read(contractFilterProvider.notifier).clearFilters();
                    break;
                }
              },
              itemBuilder: (context) => [
                const PopupMenuItem(
                  value: 'clear_filters',
                  child: Text('Clear Filters'),
                ),
              ],
            ),
          ],
          child: _buildBody(user.uid),
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
              Icon(Icons.error, size: 64, color: AppTheme.error),
              const SizedBox(height: 16),
              const Text('Error loading contracts'),
              const SizedBox(height: 8),
              Text(ErrorMessageHelper.getUserFriendlyMessage(error)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildBody(String userId) {
    if (_selectedFacilityId == null) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.business, size: 64, color: AppTheme.textTertiary),
            const SizedBox(height: 16),
            const Text(
              'No facility selected',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w600,
                color: AppTheme.textPrimary,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Please select a facility to view contracts',
              style: TextStyle(color: AppTheme.textSecondary),
            ),
          ],
        ),
      );
    }

    return Column(
      children: [
        // Facility Selection
        _buildFacilitySelector(),
        
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
    return FutureBuilder<List<dynamic>>(
      future: FacilityService.getUserFacilities(),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Padding(
            padding: EdgeInsets.all(16.0),
            child: Center(
              child: SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          );
        }

        if (snapshot.hasError) {
          return Padding(
            padding: const EdgeInsets.all(16.0),
            child: Center(
              child: Column(
                children: [
                  Icon(Icons.error, color: AppTheme.error),
                  const SizedBox(height: 8),
                  Text('Error loading facilities: ${snapshot.error}'),
                ],
              ),
            ),
          );
        }

        if (!snapshot.hasData || snapshot.data!.isEmpty) {
          return const Padding(
            padding: EdgeInsets.all(16.0),
            child: Center(
              child: Column(
                children: [
                  Icon(Icons.business, color: AppTheme.textTertiary),
                  SizedBox(height: 8),
                  Text('No facilities found. Create a facility first.'),
                ],
              ),
            ),
          );
        }

        final facilities = snapshot.data!;
        
        return Padding(
          padding: const EdgeInsets.all(16.0),
          child: Row(
            children: [
              Expanded(
                child: DropdownButtonFormField<String>(
                  value: _selectedFacilityId,
                  decoration: const InputDecoration(
                    labelText: 'Select Facility',
                    border: OutlineInputBorder(),
                    prefixIcon: Icon(Icons.business),
                  ),
                  items: facilities.map<DropdownMenuItem<String>>((facility) {
                    return DropdownMenuItem<String>(
                      value: facility.id,
                      child: Text(facility.name),
                    );
                  }).toList(),
                  onChanged: (value) {
                    if (value != null && mounted) {
                      setState(() {
                        _selectedFacilityId = value;
                      });
                    }
                  },
                ),
              ),
              if (_selectedFacilityId != null && _selectedFacilityId!.isNotEmpty) ...[
                const SizedBox(width: 8),
                IconButton(
                  onPressed: () {
                    if (_selectedFacilityId != null) {
                      context.push('/units/map?facilityId=${_selectedFacilityId!}');
                    }
                  },
                  icon: const Icon(Icons.map),
                  tooltip: 'View Map',
                  color: AppTheme.primaryBlue,
                ),
              ],
            ],
          ),
        );
      },
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
      return const Center(child: Text('No facility selected'));
    }

    return ref.watch(contractsProvider(_selectedFacilityId!)).when(
      data: (contracts) {
        final filteredContracts = _filterContracts(contracts);
        
        if (filteredContracts.isEmpty) {
          return const Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.description, size: 64, color: AppTheme.textTertiary),
                SizedBox(height: 16),
                Text('No contracts found'),
                SizedBox(height: 8),
                Text('Create your first contract to get started'),
              ],
            ),
          );
        }

        return ListView.builder(
          padding: const EdgeInsets.all(16.0),
          itemCount: filteredContracts.length,
          itemBuilder: (context, index) {
            final contract = filteredContracts[index];
            return _buildContractCard(contract);
          },
        );
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

  Widget _buildContractCard(ContractModel contract) {
    return Card(
      elevation: 0,
      margin: const EdgeInsets.only(bottom: 8.0),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: AppTheme.borderLight, width: 1),
      ),
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: _getStatusColor(contract.status),
          child: Icon(
            _getStatusIcon(contract.status),
            color: AppTheme.textOnDark,
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
                      ? AppTheme.error
                      : AppTheme.textSecondary,
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
            if (contract.status == ContractStatus.draft)
              const PopupMenuItem(
                value: 'send',
                child: Text('Send'),
              ),
            if (contract.status == ContractStatus.sent)
              const PopupMenuItem(
                value: 'sign',
                child: Text('Sign'),
              ),
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
    return Chip(
      label: Text(
        status.displayName,
        style: TextStyle(fontSize: 12, color: AppTheme.textOnDark),
      ),
      backgroundColor: _getStatusColor(status),
    );
  }

  Widget _buildTypeChip(ContractType type) {
    return Chip(
      label: Text(
        type.displayName,
        style: const TextStyle(fontSize: 12),
      ),
      backgroundColor: AppTheme.backgroundLight,
    );
  }

  Color _getStatusColor(ContractStatus status) {
    switch (status) {
      case ContractStatus.draft:
        return AppTheme.textTertiary;
      case ContractStatus.sent:
        return AppTheme.warning;
      case ContractStatus.signed:
        return AppTheme.success;
      case ContractStatus.expired:
        return AppTheme.error;
      case ContractStatus.cancelled:
        return AppTheme.error;
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
    context.push(AppRoute.contractTemplates);
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
      case 'sign':
        _signContract(contract);
        break;
      case 'delete':
        _deleteContract(contract);
        break;
    }
  }

  void _sendContract(ContractModel contract) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Send Contract'),
        content: const Text('Are you sure you want to send this contract?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () {
              Navigator.of(context).pop();
              ref.read(contractOperationsProvider.notifier).sendContract(
                facilityId: _selectedFacilityId ?? '',
                contractId: contract.id,
                sentBy: ref.read(authStateProvider).value?.uid ?? '',
              ).then((_) {
                // Refresh providers after sending contract
                if (_selectedFacilityId != null) {
                  ref.invalidate(contractsProvider(_selectedFacilityId!));
                }
              });
            },
            child: const Text('Send'),
          ),
        ],
      ),
    );
  }

  Future<void> _signContract(ContractModel contract) async {
    // Check if contract has a signing token
    try {
      final contractDoc = await FirebaseFirestore.instance
          .collection('facilities')
          .doc(contract.facilityId)
          .collection('contracts')
          .doc(contract.id)
          .get();

      final signingToken = contractDoc.data()?['signingToken'] as String?;
      if (signingToken == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Contract must be sent first to generate a signing link. Please use "Send Contract" option.'),
            backgroundColor: AppTheme.warning,
          ),
        );
        return;
      }

      // Navigate to signing screen
      context.push('${AppRoute.contractSign}?token=$signingToken');
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Error accessing contract: $e'),
          backgroundColor: AppTheme.error,
        ),
      );
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
              ref.read(contractOperationsProvider.notifier).deleteContract(_selectedFacilityId ?? '', contract.id).then((_) {
                // Refresh providers after deleting contract
                if (_selectedFacilityId != null) {
                  ref.invalidate(contractsProvider(_selectedFacilityId!));
                }
              });
            },
            style: ElevatedButton.styleFrom(backgroundColor: AppTheme.error),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
  }
}
