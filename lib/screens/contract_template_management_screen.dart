import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../models/contract_template_model.dart';
import '../models/contract_model.dart';
import '../providers/contract_provider.dart';
import '../services/contract_service.dart';
import '../services/facility_service.dart';
import '../theme/app_theme.dart';
import '../widgets/modern_page_wrapper.dart';
import '../utils/error_message_helper.dart';
import '../services/modern_navigation_service.dart';
import '../router/app_router.dart';
import '../widgets/keyboard_scrollable.dart';

class ContractTemplateManagementScreen extends ConsumerStatefulWidget {
  final String? facilityId;
  
  const ContractTemplateManagementScreen({super.key, this.facilityId});

  @override
  ConsumerState<ContractTemplateManagementScreen> createState() => _ContractTemplateManagementScreenState();
}

class _ContractTemplateManagementScreenState extends ConsumerState<ContractTemplateManagementScreen> {
  String? _selectedFacilityId;
  bool _isLoadingFacility = true;

  @override
  void initState() {
    super.initState();
    _selectedFacilityId = widget.facilityId;
    if (_selectedFacilityId == null) {
      _loadFirstFacility();
    } else {
      _isLoadingFacility = false;
    }
  }

  Future<void> _loadFirstFacility() async {
    try {
      final facilities = await FacilityService.getUserFacilities();
      if (facilities.isNotEmpty && mounted) {
        setState(() {
          _selectedFacilityId = facilities.first.id;
          _isLoadingFacility = false;
        });
      } else if (mounted) {
        setState(() {
          _isLoadingFacility = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isLoadingFacility = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoadingFacility) {
      return ModernPageWrapper(
        currentRoute: '/contracts',
        title: 'Contract Templates',
        onNavigate: (route) {
          ModernNavigationService.navigateToRoute(context, route);
        },
        child: const Center(child: CircularProgressIndicator()),
      );
    }

    if (_selectedFacilityId == null) {
      return ModernPageWrapper(
        currentRoute: '/contracts',
        title: 'Contract Templates',
        onNavigate: (route) {
          ModernNavigationService.navigateToRoute(context, route);
        },
        child: const Center(
          child: Text('No facility selected. Please create a facility first.'),
        ),
      );
    }

    final templatesAsync = ref.watch(contractTemplatesProvider(_selectedFacilityId!));

    return ModernPageWrapper(
      currentRoute: '/contracts',
      title: 'Contract Templates',
      onNavigate: (route) {
        ModernNavigationService.navigateToRoute(context, route);
      },
      actions: [
        IconButton(
          icon: const Icon(Icons.add),
          onPressed: () => _showCreateTemplateDialog(),
          tooltip: 'Create Template',
        ),
      ],
      child: templatesAsync.when(
        data: (templates) {
          if (templates.isEmpty) {
            return Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.description, size: 64, color: AppTheme.textTertiary),
                  const SizedBox(height: 16),
                  Text(
                    'No Templates Yet',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Create your first contract template to get started',
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: AppTheme.textSecondary,
                    ),
                  ),
                  const SizedBox(height: 24),
                  ElevatedButton.icon(
                    onPressed: () => _showCreateTemplateDialog(),
                    icon: const Icon(Icons.add),
                    label: const Text('Create Template'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppTheme.primaryBlueDark,
                      foregroundColor: AppTheme.textOnDark,
                      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                    ),
                  ),
                ],
              ),
            );
          }

          return ListView.builder(
            padding: const EdgeInsets.all(16),
            itemCount: templates.length,
            itemBuilder: (context, index) {
              final template = templates[index];
              return Card(
                margin: const EdgeInsets.only(bottom: 12),
                child: ListTile(
                  leading: Icon(
                    _getIconForType(template.type),
                    color: AppTheme.primaryBlueDark,
                  ),
                  title: Text(
                    template.name,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  subtitle: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const SizedBox(height: 4),
                      Text(template.description),
                      const SizedBox(height: 4),
                      Wrap(
                        spacing: 8,
                        children: [
                          Chip(
                            label: Text(template.type.name.toUpperCase()),
                            labelStyle: const TextStyle(fontSize: 10),
                            padding: EdgeInsets.zero,
                          ),
                          if (template.fileUrl != null)
                            const Chip(
                              label: Text('PDF'),
                              labelStyle: TextStyle(fontSize: 10),
                              padding: EdgeInsets.zero,
                            ),
                          Chip(
                            label: Text('${template.signers.length} signers'),
                            labelStyle: const TextStyle(fontSize: 10),
                            padding: EdgeInsets.zero,
                          ),
                        ],
                      ),
                    ],
                  ),
                  trailing: PopupMenuButton<String>(
                    onSelected: (value) {
                      switch (value) {
                        case 'view':
                          _viewTemplate(template);
                          break;
                        case 'edit':
                          _editTemplate(template);
                          break;
                        case 'delete':
                          _deleteTemplate(template);
                          break;
                      }
                    },
                    itemBuilder: (context) => [
                      const PopupMenuItem(
                        value: 'view',
                        child: Row(
                          children: [
                            Icon(Icons.visibility, size: 20),
                            SizedBox(width: 8),
                            Text('View'),
                          ],
                        ),
                      ),
                      const PopupMenuItem(
                        value: 'edit',
                        child: Row(
                          children: [
                            Icon(Icons.edit, size: 20),
                            SizedBox(width: 8),
                            Text('Edit'),
                          ],
                        ),
                      ),
                      const PopupMenuItem(
                        value: 'delete',
                        child: Row(
                          children: [
                            Icon(Icons.delete, size: 20, color: AppTheme.error),
                            SizedBox(width: 8),
                            Text('Delete', style: TextStyle(color: AppTheme.error)),
                          ],
                        ),
                      ),
                    ],
                  ),
                  onTap: () => _viewTemplate(template),
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
              const SizedBox(height: 16),
              const Text('Error loading templates'),
              const SizedBox(height: 8),
              Text(ErrorMessageHelper.getUserFriendlyMessage(error)),
            ],
          ),
        ),
      ),
    );
  }

  IconData _getIconForType(ContractType type) {
    switch (type) {
      case ContractType.lease:
        return Icons.home;
      case ContractType.rental:
        return Icons.apartment;
      case ContractType.storage:
        return Icons.storage;
      case ContractType.custom:
        return Icons.description;
    }
  }

  void _showCreateTemplateDialog() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Create Template'),
        content: const Text('Template creation form will be implemented here. For now, you can create templates programmatically or use the default templates.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Close'),
          ),
          ElevatedButton(
            onPressed: () {
              Navigator.of(context).pop();
              _createDefaultTemplates();
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: AppTheme.primaryBlueDark,
              foregroundColor: AppTheme.textOnDark,
            ),
            child: const Text('Create Default Templates'),
          ),
        ],
      ),
    );
  }

  Future<void> _createDefaultTemplates() async {
    if (_selectedFacilityId == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Please select a facility first'),
          backgroundColor: AppTheme.error,
        ),
      );
      return;
    }

    try {
      // Create default storage rental agreement template
      await ContractService.createContractTemplate(
        facilityId: _selectedFacilityId!,
        name: 'Standard Storage Rental Agreement',
        description: 'A standard storage unit rental agreement template',
        content: _getDefaultStorageAgreementContent(),
        type: ContractType.storage,
      );

      // Create default lease agreement template
      await ContractService.createContractTemplate(
        facilityId: _selectedFacilityId!,
        name: 'Standard Lease Agreement',
        description: 'A standard lease agreement template',
        content: _getDefaultLeaseAgreementContent(),
        type: ContractType.lease,
      );

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Default templates created successfully!'),
            backgroundColor: AppTheme.success,
          ),
        );
        // Refresh templates
        ref.invalidate(contractTemplatesProvider(_selectedFacilityId!));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error creating templates: $e'),
            backgroundColor: AppTheme.error,
          ),
        );
      }
    }
  }

  String _getDefaultStorageAgreementContent() {
    return '''
# Storage Unit Rental Agreement

## Parties
This agreement is entered into between:
- **Facility Owner**: [Facility Name]
- **Tenant**: [Tenant Name]

## Terms and Conditions

1. **Rental Period**: This agreement is effective from [Start Date] to [End Date].

2. **Monthly Rent**: The monthly rental fee is \$[Amount] due on the [Day] of each month.

3. **Security Deposit**: A security deposit of \$[Amount] is required.

4. **Access**: Tenant will be provided with gate access code: [Code]

5. **Prohibited Items**: The following items are prohibited:
   - Flammable materials
   - Hazardous substances
   - Perishable items
   - Illegal items

6. **Liability**: Facility is not responsible for damage to stored items.

7. **Termination**: Either party may terminate this agreement with 30 days written notice.

## Signatures

By signing below, both parties agree to the terms and conditions outlined in this agreement.

**Facility Owner**: _________________ Date: ___________

**Tenant**: _________________ Date: ___________
''';
  }

  String _getDefaultLeaseAgreementContent() {
    return '''
# Lease Agreement

## Parties
This lease agreement is entered into between:
- **Landlord**: [Facility Name]
- **Tenant**: [Tenant Name]

## Property
Unit Number: [Unit Number]
Address: [Address]

## Terms

1. **Lease Term**: [Start Date] to [End Date]

2. **Monthly Rent**: \$[Amount] per month, due on the [Day] of each month.

3. **Security Deposit**: \$[Amount]

4. **Utilities**: [Included/Not Included]

5. **Maintenance**: Tenant is responsible for [Maintenance Responsibilities]

6. **Termination**: This lease may be terminated with [Notice Period] days written notice.

## Signatures

**Landlord**: _________________ Date: ___________

**Tenant**: _________________ Date: ___________
''';
  }

  void _viewTemplate(ContractTemplateModel template) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(template.name),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                template.description,
                style: Theme.of(context).textTheme.bodyMedium,
              ),
              const SizedBox(height: 16),
              Text(
                'Type: ${template.type.name}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 8),
              Text(
                'Signers: ${template.signers.length}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 16),
              const Divider(),
              const SizedBox(height: 8),
              Text(
                'Content Preview:',
                style: Theme.of(context).textTheme.titleSmall,
              ),
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: AppTheme.backgroundLight,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  template.content.length > 200
                      ? '${template.content.substring(0, 200)}...'
                      : template.content,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  void _editTemplate(ContractTemplateModel template) {
    if (_selectedFacilityId == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Please select a facility first'),
          backgroundColor: AppTheme.error,
        ),
      );
      return;
    }

    final nameController = TextEditingController(text: template.name);
    final descriptionController = TextEditingController(text: template.description);
    final contentController = TextEditingController(text: template.content);
    ContractType selectedType = template.type;

    showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Edit Template'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TextField(
                  controller: nameController,
                  decoration: const InputDecoration(
                    labelText: 'Template Name',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: descriptionController,
                  decoration: const InputDecoration(
                    labelText: 'Description',
                    border: OutlineInputBorder(),
                  ),
                  maxLines: 2,
                ),
                const SizedBox(height: 16),
                DropdownButtonFormField<ContractType>(
                  value: selectedType,
                  decoration: const InputDecoration(
                    labelText: 'Contract Type',
                    border: OutlineInputBorder(),
                  ),
                  items: ContractType.values.map((type) {
                    return DropdownMenuItem(
                      value: type,
                      child: Text(type.name.toUpperCase()),
                    );
                  }).toList(),
                  onChanged: (value) {
                    if (value != null) {
                      setDialogState(() {
                        selectedType = value;
                      });
                    }
                  },
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: contentController,
                  decoration: const InputDecoration(
                    labelText: 'Template Content',
                    border: OutlineInputBorder(),
                    hintText: 'Enter template content or markdown...',
                  ),
                  maxLines: 10,
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: () async {
                if (nameController.text.trim().isEmpty) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('Template name is required'),
                      backgroundColor: AppTheme.error,
                    ),
                  );
                  return;
                }

                Navigator.of(context).pop();
                await _updateTemplate(
                  template.id,
                  nameController.text.trim(),
                  descriptionController.text.trim(),
                  contentController.text.trim(),
                  selectedType,
                );
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: AppTheme.primaryBlueDark,
                foregroundColor: AppTheme.textOnDark,
              ),
              child: const Text('Save Changes'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _updateTemplate(
    String templateId,
    String name,
    String description,
    String content,
    ContractType type,
  ) async {
    if (_selectedFacilityId == null) return;

    try {
      await ContractService.updateContractTemplate(
        facilityId: _selectedFacilityId!,
        templateId: templateId,
        name: name,
        description: description,
        content: content,
        type: type,
      );

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Template updated successfully!'),
            backgroundColor: AppTheme.success,
          ),
        );
        // Refresh templates
        ref.invalidate(contractTemplatesProvider(_selectedFacilityId!));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(ErrorMessageHelper.getUserFriendlyMessage(e)),
            backgroundColor: AppTheme.error,
          ),
        );
      }
    }
  }

  Future<void> _deleteTemplate(ContractTemplateModel template) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete Template'),
        content: Text('Are you sure you want to delete "${template.name}"? This action cannot be undone.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: ElevatedButton.styleFrom(
              backgroundColor: AppTheme.error,
              foregroundColor: AppTheme.textOnDark,
            ),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (confirm == true && _selectedFacilityId != null) {
      try {
        await ContractService.deleteContractTemplate(
          facilityId: _selectedFacilityId!,
          templateId: template.id,
        );
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Template deleted successfully'),
              backgroundColor: AppTheme.success,
            ),
          );
          // Refresh templates
          ref.invalidate(contractTemplatesProvider(_selectedFacilityId!));
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Error deleting template: $e'),
              backgroundColor: AppTheme.error,
            ),
          );
        }
      }
    }
  }
}

