import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/foundation.dart';
import '../models/unit_model.dart';
import '../models/unit_type_model.dart';
import '../models/tenant_model.dart';
import '../providers/unit_provider.dart';
import '../providers/tenant_provider.dart' as tenant_provider;
import '../services/unit_service.dart';
import '../providers/auth_provider.dart';
import '../theme/app_theme.dart';
import '../utils/error_message_helper.dart';
import '../widgets/keyboard_scrollable.dart';

class UnitCreationScreen extends ConsumerStatefulWidget {
  final String facilityId;
  final UnitModel? unit; // For editing existing unit

  const UnitCreationScreen({
    super.key,
    required this.facilityId,
    this.unit,
  });

  @override
  ConsumerState<UnitCreationScreen> createState() => _UnitCreationScreenState();
}

class _UnitCreationScreenState extends ConsumerState<UnitCreationScreen> {
  final _formKey = GlobalKey<FormState>();
  final _unitNumberController = TextEditingController();
  final _monthlyRateController = TextEditingController();
  final _securityDepositController = TextEditingController();
  final _descriptionController = TextEditingController();
  final _notesController = TextEditingController();
  final _widthController = TextEditingController();
  final _heightController = TextEditingController();
  final _depthController = TextEditingController();

  String _selectedUnitType = 'standard';
  UnitStatus _selectedStatus = UnitStatus.available;
  String? _selectedTenantId;
  String? _selectedTenantName;
  List<String> _selectedFeatures = [];
  bool _isLoading = false;
  String? _errorMessage;

  List<String> _availableFeatures = [
    'Climate Control',
    'Security Camera',
    'Alarm System',
    '24/7 Access',
    'Drive-up Access',
    'Ground Floor',
    'Elevator Access',
    'Loading Dock',
  ];

  @override
  void initState() {
    super.initState();
    _loadUnitTypes();
    if (widget.unit != null) {
      _populateFields();
    }
  }

  @override
  void dispose() {
    _unitNumberController.dispose();
    _monthlyRateController.dispose();
    _securityDepositController.dispose();
    _descriptionController.dispose();
    _notesController.dispose();
    _widthController.dispose();
    _heightController.dispose();
    _depthController.dispose();
    super.dispose();
  }

  Future<void> _loadUnitTypes() async {
    // Unit types are now hardcoded since getUnitTypesForFacility was removed
    // This method is kept for potential future use but currently does nothing
    // as unit types are no longer stored in state
  }

  void _populateFields() {
    if (widget.unit == null) return;

    final unit = widget.unit!;
    _unitNumberController.text = unit.unitNumber;
    _monthlyRateController.text = unit.monthlyRate.toString();
    _securityDepositController.text = unit.securityDeposit?.toString() ?? '';
    _descriptionController.text = unit.description ?? '';
    _notesController.text = unit.notes ?? '';
    _selectedUnitType = unit.unitType;
    _selectedStatus = unit.status;
    // Guard: Only populate tenant data if status is NOT "Available"
    if (unit.status == UnitStatus.available) {
      _selectedTenantId = null;
      _selectedTenantName = null;
    } else {
      _selectedTenantId = unit.tenantId;
      _selectedTenantName = unit.tenantName;
    }
    _selectedFeatures = unit.features ?? [];

    if (unit.dimensions != null) {
      _widthController.text = unit.dimensions!['width']?.toString() ?? '';
      _heightController.text = unit.dimensions!['height']?.toString() ?? '';
      _depthController.text = unit.dimensions!['depth']?.toString() ?? '';
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.unit == null ? 'Create Unit' : 'Edit Unit'),
        centerTitle: true,
        actions: [
          if (widget.unit != null)
            IconButton(
              onPressed: _showDeleteDialog,
              icon: const Icon(Icons.delete),
              tooltip: 'Delete Unit',
            ),
        ],
      ),
      body: Form(
        key: _formKey,
        child: KeyboardScrollable(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Unit Number
              TextFormField(
                controller: _unitNumberController,
                decoration: const InputDecoration(
                  labelText: 'Unit Number *',
                  hintText: 'e.g., A101, B205',
                  border: OutlineInputBorder(),
                  prefixIcon: Icon(Icons.tag),
                ),
                validator: (value) {
                  if (value == null || value.trim().isEmpty) {
                    return 'Unit number is required';
                  }
                  return null;
                },
              ),
              const SizedBox(height: 16),

              // Unit Type
              DropdownButtonFormField<String>(
                value: _selectedUnitType,
                decoration: const InputDecoration(
                  labelText: 'Unit Type *',
                  border: OutlineInputBorder(),
                  prefixIcon: Icon(Icons.category),
                ),
                items: [
                  const DropdownMenuItem(
                    value: 'standard',
                    child: Text('Standard'),
                  ),
                  const DropdownMenuItem(
                    value: 'climateControlled',
                    child: Text('Climate Controlled'),
                  ),
                  const DropdownMenuItem(
                    value: 'vehicle',
                    child: Text('Vehicle Storage'),
                  ),
                  const DropdownMenuItem(
                    value: 'document',
                    child: Text('Document Storage'),
                  ),
                  const DropdownMenuItem(
                    value: 'wine',
                    child: Text('Wine Storage'),
                  ),
                  const DropdownMenuItem(
                    value: 'outdoor',
                    child: Text('Outdoor Storage'),
                  ),
                ],
                onChanged: (value) {
                  if (value != null && mounted) {
                    setState(() {
                      _selectedUnitType = value;
                    });
                  }
                },
              ),
              const SizedBox(height: 16),

              // Monthly Rate
              TextFormField(
                controller: _monthlyRateController,
                decoration: const InputDecoration(
                  labelText: 'Monthly Rate *',
                  hintText: '0.00',
                  border: OutlineInputBorder(),
                  prefixIcon: Icon(Icons.attach_money),
                ),
                keyboardType: TextInputType.number,
                validator: (value) {
                  if (value == null || value.trim().isEmpty) {
                    return 'Monthly rate is required';
                  }
                  final rate = double.tryParse(value);
                  if (rate == null || rate < 0) {
                    return 'Please enter a valid monthly rate';
                  }
                  return null;
                },
              ),
              const SizedBox(height: 16),

              // Security Deposit
              TextFormField(
                controller: _securityDepositController,
                decoration: const InputDecoration(
                  labelText: 'Security Deposit',
                  hintText: '0.00',
                  border: OutlineInputBorder(),
                  prefixIcon: Icon(Icons.security),
                ),
                keyboardType: TextInputType.number,
                validator: (value) {
                  if (value != null && value.isNotEmpty) {
                    final deposit = double.tryParse(value);
                    if (deposit == null || deposit < 0) {
                      return 'Please enter a valid security deposit';
                    }
                  }
                  return null;
                },
              ),
              const SizedBox(height: 16),

              // Dimensions
              Text(
                'Dimensions (feet)',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 8),
              // Preset sizes
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  _buildPresetSizeChip('5x10', 5, 10, 10),
                  _buildPresetSizeChip('10x10', 10, 10, 10),
                  _buildPresetSizeChip('10x15', 10, 15, 10),
                  _buildPresetSizeChip('10x20', 10, 20, 10),
                  _buildPresetSizeChip('10x25', 10, 25, 10),
                  _buildPresetSizeChip('10x30', 10, 30, 10),
                  _buildPresetSizeChip('15x15', 15, 15, 10),
                  _buildPresetSizeChip('20x20', 20, 20, 10),
                ],
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: TextFormField(
                      controller: _widthController,
                      decoration: const InputDecoration(
                        labelText: 'Width (ft)',
                        border: OutlineInputBorder(),
                      ),
                      keyboardType: TextInputType.number,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: TextFormField(
                      controller: _depthController,
                      decoration: const InputDecoration(
                        labelText: 'Depth/Length (ft)',
                        border: OutlineInputBorder(),
                      ),
                      keyboardType: TextInputType.number,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: TextFormField(
                      controller: _heightController,
                      decoration: const InputDecoration(
                        labelText: 'Height (ft)',
                        border: OutlineInputBorder(),
                      ),
                      keyboardType: TextInputType.number,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),

              // Features
              Text(
                'Features',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: _availableFeatures.map((feature) {
                  final isSelected = _selectedFeatures.contains(feature);
                  return FilterChip(
                    label: Text(feature),
                    selected: isSelected,
                    onSelected: (selected) {
                      if (mounted) {
                        setState(() {
                          if (selected) {
                            _selectedFeatures.add(feature);
                          } else {
                            _selectedFeatures.remove(feature);
                          }
                        });
                      }
                    },
                  );
                }).toList(),
              ),
              const SizedBox(height: 16),

              // Description
              TextFormField(
                controller: _descriptionController,
                decoration: const InputDecoration(
                  labelText: 'Description',
                  hintText: 'Unit description...',
                  border: OutlineInputBorder(),
                  prefixIcon: Icon(Icons.description),
                ),
                maxLines: 3,
              ),
              const SizedBox(height: 16),

              // Notes
              TextFormField(
                controller: _notesController,
                decoration: const InputDecoration(
                  labelText: 'Notes',
                  hintText: 'Internal notes...',
                  border: OutlineInputBorder(),
                  prefixIcon: Icon(Icons.note),
                ),
                maxLines: 2,
              ),
              const SizedBox(height: 24),

              // Status Selection
              DropdownButtonFormField<UnitStatus>(
                value: _selectedStatus,
                decoration: const InputDecoration(
                  labelText: 'Status *',
                  border: OutlineInputBorder(),
                  prefixIcon: Icon(Icons.info),
                ),
                items: UnitStatus.values.map((status) {
                  return DropdownMenuItem<UnitStatus>(
                    value: status,
                    child: Text(status.displayName),
                  );
                }).toList(),
                onChanged: (value) {
                  if (value != null && mounted) {
                    setState(() {
                      _selectedStatus = value;
                      // Clear tenant fields when status changes to "Available"
                      if (value == UnitStatus.available) {
                        _selectedTenantId = null;
                        _selectedTenantName = null;
                      }
                    });
                  }
                },
              ),
              const SizedBox(height: 16),

              // Tenant Selection (only show if status is not "Available" or if editing an occupied unit)
              if (_selectedStatus != UnitStatus.available || (widget.unit != null && widget.unit!.tenantId != null && widget.unit!.tenantId!.isNotEmpty)) ...[
                Consumer(
                  builder: (context, ref, child) {
                    final tenantsAsync = ref.watch(tenant_provider.facilityTenantsProvider(widget.facilityId));
                    
                    return tenantsAsync.when(
                      data: (tenants) {
                        if (tenants.isEmpty && _selectedStatus != UnitStatus.available) {
                          return Container(
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(
                              color: AppTheme.warning.withValues(alpha: 0.1),
                              border: Border.all(color: AppTheme.warning),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Row(
                              children: [
                                Icon(Icons.person_off, color: AppTheme.warning, size: 20),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    'No tenants available. Unit will be saved as ${_selectedStatus.displayName} without tenant assignment.',
                                    style: TextStyle(
                                      color: AppTheme.warning,
                                      fontSize: 12,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          );
                        }

                        if (_selectedStatus == UnitStatus.available) {
                          // If unit has tenant data but status is Available, show a message to clear it
                          if (widget.unit != null && 
                              widget.unit!.tenantId != null && 
                              widget.unit!.tenantId!.isNotEmpty) {
                            return Container(
                              margin: const EdgeInsets.only(bottom: 16),
                              padding: const EdgeInsets.all(12),
                              decoration: BoxDecoration(
                                color: AppTheme.warning.withValues(alpha: 0.1),
                                border: Border.all(color: AppTheme.warning),
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: Row(
                                children: [
                                  Icon(Icons.info_outline, color: AppTheme.warning, size: 20),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          'Unit has tenant assigned but status is Available',
                                          style: TextStyle(
                                            color: AppTheme.warning,
                                            fontSize: 12,
                                            fontWeight: FontWeight.w600,
                                          ),
                                        ),
                                        const SizedBox(height: 4),
                                        Text(
                                          'Tenant: ${widget.unit!.tenantName ?? 'Unknown'}. '
                                          'Saving will automatically clear the tenant assignment.',
                                          style: TextStyle(
                                            color: AppTheme.warning,
                                            fontSize: 11,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                            );
                          }
                          return const SizedBox.shrink();
                        }

                        // Get all units to check for existing tenant assignments
                        final unitsAsync = ref.watch(facilityUnitsProvider(widget.facilityId));
                        
                        return unitsAsync.when(
                          data: (units) {
                            // Find tenants already assigned to other units (excluding current unit if editing)
                            final assignedTenantIds = units
                                .where((unit) => widget.unit == null || unit.id != widget.unit!.id)
                                .where((unit) => unit.tenantId != null && unit.tenantId!.isNotEmpty)
                                .map((unit) => unit.tenantId!)
                                .toSet();
                            
                            return DropdownButtonFormField<String>(
                              value: _selectedTenantId,
                              decoration: const InputDecoration(
                                labelText: 'Assign Tenant (Optional)',
                                border: OutlineInputBorder(),
                                prefixIcon: Icon(Icons.person),
                                helperText: 'Select a tenant to assign to this unit',
                              ),
                              items: [
                                const DropdownMenuItem<String>(
                                  value: null,
                                  child: Text('No tenant assigned'),
                                ),
                                ...tenants.map((tenant) {
                                  final isAlreadyAssigned = assignedTenantIds.contains(tenant.id);
                                  return DropdownMenuItem<String>(
                                    value: tenant.id,
                                    enabled: !isAlreadyAssigned,
                                    child: Row(
                                      children: [
                                        if (isAlreadyAssigned) ...[
                                          Icon(Icons.warning, size: 16, color: AppTheme.warning),
                                          const SizedBox(width: 8),
                                        ],
                                        Expanded(
                                          child: Text(
                                            '${tenant.name}${tenant.unitNumber.isNotEmpty ? ' (${tenant.unitNumber})' : ''}',
                                            style: TextStyle(
                                              color: isAlreadyAssigned ? AppTheme.textTertiary : null,
                                            ),
                                          ),
                                        ),
                                        if (isAlreadyAssigned)
                                          Text(
                                            ' (Assigned)',
                                            style: TextStyle(
                                              color: AppTheme.warning,
                                              fontSize: 12,
                                              fontStyle: FontStyle.italic,
                                            ),
                                          ),
                                      ],
                                    ),
                                  );
                                }),
                              ],
                              onChanged: (tenantId) {
                                if (mounted) {
                                  // Check if tenant is already assigned
                                  if (tenantId != null && assignedTenantIds.contains(tenantId)) {
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      SnackBar(
                                        content: Text('This tenant is already assigned to another unit. Please unassign them first.'),
                                        backgroundColor: AppTheme.warning,
                                        duration: const Duration(seconds: 3),
                                      ),
                                    );
                                    return;
                                  }
                                  
                                  setState(() {
                                    _selectedTenantId = tenantId;
                                    if (tenantId != null) {
                                      final tenant = tenants.firstWhere((t) => t.id == tenantId);
                                      _selectedTenantName = tenant.name;
                                    } else {
                                      _selectedTenantName = null;
                                    }
                                  });
                                }
                              },
                            );
                          },
                          loading: () => DropdownButtonFormField<String>(
                            value: _selectedTenantId,
                            decoration: const InputDecoration(
                              labelText: 'Assign Tenant (Optional)',
                              border: OutlineInputBorder(),
                              prefixIcon: Icon(Icons.person),
                            ),
                            items: [
                              const DropdownMenuItem<String>(
                                value: null,
                                child: Text('Loading...'),
                              ),
                            ],
                            onChanged: null,
                          ),
                          error: (_, __) => DropdownButtonFormField<String>(
                            value: _selectedTenantId,
                            decoration: const InputDecoration(
                              labelText: 'Assign Tenant (Optional)',
                              border: OutlineInputBorder(),
                              prefixIcon: Icon(Icons.person),
                            ),
                            items: [
                              const DropdownMenuItem<String>(
                                value: null,
                                child: Text('Error loading units'),
                              ),
                            ],
                            onChanged: null,
                          ),
                        );
                      },
                      loading: () => const SizedBox(
                        height: 20,
                        width: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                      error: (error, _) => Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: AppTheme.error.withValues(alpha: 0.1),
                          border: Border.all(color: AppTheme.error),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(
                          'Error loading tenants: ${ErrorMessageHelper.getUserFriendlyMessage(error)}',
                          style: TextStyle(color: AppTheme.error, fontSize: 12),
                        ),
                      ),
                    );
                  },
                ),
                const SizedBox(height: 16),
              ],

              // Error Message
              if (_errorMessage != null)
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: AppTheme.error.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: AppTheme.error),
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.error, color: AppTheme.error),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          _errorMessage!,
                          style: TextStyle(color: AppTheme.error),
                        ),
                      ),
                    ],
                  ),
                ),

              if (_errorMessage != null) const SizedBox(height: 16),

              // Submit Button
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: _isLoading ? null : _submitForm,
                  style: ElevatedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 16),
                  ),
                  child: _isLoading
                      ? const CircularProgressIndicator(color: AppTheme.textOnDark)
                      : Text(
                          widget.unit == null ? 'Create Unit' : 'Update Unit',
                          style: const TextStyle(fontSize: 16),
                        ),
                ),
              ),
            ],
          ),
        ),
      ),
      ),
    );
  }

  Widget _buildPresetSizeChip(String label, double width, double depth, double height) {
    return ActionChip(
      label: Text(label),
      onPressed: () {
        setState(() {
          _widthController.text = width.toStringAsFixed(0);
          _depthController.text = depth.toStringAsFixed(0);
          _heightController.text = height.toStringAsFixed(0);
        });
      },
      backgroundColor: AppTheme.primaryBlue.withValues(alpha: 0.1),
      side: BorderSide(color: AppTheme.primaryBlue),
    );
  }

  Future<void> _submitForm() async {
    if (!_formKey.currentState!.validate()) return;

    if (mounted) {
      setState(() {
        _isLoading = true;
        _errorMessage = null;
      });
    }

    try {
      final user = ref.read(authStateProvider).value;
      if (user == null) {
        throw Exception('User not authenticated');
      }

      final dimensions = <String, dynamic>{};
      if (_widthController.text.isNotEmpty) {
        dimensions['width'] = double.tryParse(_widthController.text);
      }
      if (_heightController.text.isNotEmpty) {
        dimensions['height'] = double.tryParse(_heightController.text);
      }
      if (_depthController.text.isNotEmpty) {
        dimensions['depth'] = double.tryParse(_depthController.text);
      }

      if (widget.unit == null) {
        // Create new unit
        await UnitService.createUnit(
          facilityId: widget.facilityId,
          unitNumber: _unitNumberController.text.trim(),
          unitType: _selectedUnitType,
          monthlyRate: double.parse(_monthlyRateController.text),
          description: _descriptionController.text.trim().isEmpty 
              ? null 
              : _descriptionController.text.trim(),
          dimensions: dimensions.isEmpty ? null : dimensions,
          features: _selectedFeatures.isEmpty ? null : _selectedFeatures,
          notes: _notesController.text.trim().isEmpty 
              ? null 
              : _notesController.text.trim(),
          securityDeposit: _securityDepositController.text.trim().isEmpty 
              ? null 
              : double.tryParse(_securityDepositController.text),
        );

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Unit created successfully!')),
          );
          // Invalidate providers to refresh unit lists
          ref.invalidate(facilityUnitsProvider(widget.facilityId));
          Navigator.of(context).pop();
        }
      } else {
        // Update existing unit
        // Guard: Clear tenant data when status is "Available"
        final finalTenantId = _selectedStatus == UnitStatus.available ? null : _selectedTenantId;
        final finalTenantName = _selectedStatus == UnitStatus.available ? null : _selectedTenantName;
        
        // Validate tenant isn't already assigned to another unit
        if (finalTenantId != null && finalTenantId.isNotEmpty) {
          final allUnits = await UnitService.getUnitsForFacility(widget.facilityId);
          final conflictingUnits = allUnits.where(
            (u) => u.id != widget.unit!.id && u.tenantId == finalTenantId,
          ).toList();
          final conflictingUnit = conflictingUnits.isNotEmpty ? conflictingUnits.first : null;
          
          if (conflictingUnit != null) {
            if (mounted) {
              setState(() {
                _errorMessage = 'This tenant is already assigned to unit ${conflictingUnit.unitNumber}. Please unassign them first.';
                _isLoading = false;
              });
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text('${finalTenantName} is already assigned to unit ${conflictingUnit.unitNumber}'),
                  backgroundColor: AppTheme.error,
                  duration: const Duration(seconds: 4),
                ),
              );
            }
            return;
          }
        }
        
        await UnitService.updateUnit(
          facilityId: widget.facilityId,
          unitId: widget.unit!.id,
          unitNumber: _unitNumberController.text.trim(),
          unitType: _selectedUnitType,
          status: _selectedStatus,
          tenantId: finalTenantId,
          tenantName: finalTenantName,
          monthlyRate: double.parse(_monthlyRateController.text),
          securityDeposit: _securityDepositController.text.trim().isEmpty 
              ? null 
              : double.tryParse(_securityDepositController.text),
          description: _descriptionController.text.trim().isEmpty 
              ? null 
              : _descriptionController.text.trim(),
          dimensions: dimensions.isEmpty ? null : dimensions,
          features: _selectedFeatures.isEmpty ? null : _selectedFeatures,
          notes: _notesController.text.trim().isEmpty 
              ? null 
              : _notesController.text.trim(),
        );

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Unit updated successfully!')),
          );
          // Invalidate providers to refresh unit lists
          ref.invalidate(facilityUnitsProvider(widget.facilityId));
          Navigator.of(context).pop();
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _errorMessage = 'Failed to ${widget.unit == null ? 'create' : 'update'} unit: ${ErrorMessageHelper.getUserFriendlyMessage(e)}';
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  void _showDeleteDialog() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete Unit'),
        content: Text(
          'Are you sure you want to delete unit ${widget.unit?.unitNumber}? This action cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () async {
              Navigator.of(context).pop();
              await _deleteUnit();
            },
            style: TextButton.styleFrom(foregroundColor: AppTheme.error),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
  }

  Future<void> _deleteUnit() async {
    if (widget.unit == null) return;

    if (mounted) {
      setState(() {
        _isLoading = true;
        _errorMessage = null;
      });
    }

    try {
      await UnitService.deleteUnit(widget.facilityId, widget.unit!.id);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Unit deleted successfully!')),
        );
        Navigator.of(context).pop();
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _errorMessage = 'Failed to delete unit: ${ErrorMessageHelper.getUserFriendlyMessage(e)}';
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }
}
