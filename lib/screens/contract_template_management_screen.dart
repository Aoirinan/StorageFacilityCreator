import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../models/contract_template_model.dart';
import '../models/contract_model.dart';
import '../models/facility_model.dart';
import '../providers/contract_provider.dart';
import '../providers/search_provider.dart';
import '../services/contract_service.dart';
import '../services/facility_service.dart';
import '../theme/app_theme.dart';
import '../widgets/modern_page_wrapper.dart';
import '../utils/error_message_helper.dart';
import '../services/modern_navigation_service.dart';
import '../router/app_route.dart';
import '../router/app_router.dart';
import '../widgets/keyboard_scrollable.dart';
import '../widgets/signature_field_configurator.dart';
import 'package:url_launcher/url_launcher.dart';

class ContractTemplateManagementScreen extends ConsumerStatefulWidget {
  final String? facilityId;
  
  const ContractTemplateManagementScreen({super.key, this.facilityId});

  @override
  ConsumerState<ContractTemplateManagementScreen> createState() => _ContractTemplateManagementScreenState();
}

class _BulletItem extends StatelessWidget {
  final String text;

  const _BulletItem({required this.text});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('• ', style: TextStyle(color: AppTheme.primaryBlueDark, fontWeight: FontWeight.bold)),
          Expanded(child: Text(text)),
        ],
      ),
    );
  }
}

// Sentinel value meaning "show all facilities"
const _kAllFacilities = '__all__';

class _ContractTemplateManagementScreenState extends ConsumerState<ContractTemplateManagementScreen> {
  // null = loading; _kAllFacilities = all; otherwise a real facility id
  String? _selectedFacilityId;
  bool _isLoadingFacility = true;

  @override
  void initState() {
    super.initState();
    _selectedFacilityId = widget.facilityId;
    if (_selectedFacilityId == null) {
      _loadInitialFacility();
    } else {
      _isLoadingFacility = false;
    }
  }

  Future<void> _loadInitialFacility() async {
    try {
      // Respect the global facility picker if one is already selected
      final globalFacility = ref.read(selectedFacilityProvider);
      if (globalFacility != null && mounted) {
        setState(() {
          _selectedFacilityId = globalFacility.id;
          _isLoadingFacility = false;
        });
        return;
      }
      // Otherwise default to "All Facilities"
      if (mounted) {
        setState(() {
          _selectedFacilityId = _kAllFacilities;
          _isLoadingFacility = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _selectedFacilityId = _kAllFacilities;
          _isLoadingFacility = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    // Sync with global facility picker: when the user picks a facility from the
    // top-level picker, mirror it in this screen's local dropdown.
    final globalFacility = ref.watch(selectedFacilityProvider);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final globalId = globalFacility?.id;
      if (globalId != null && _selectedFacilityId != globalId) {
        setState(() => _selectedFacilityId = globalId);
      }
    });

    if (_isLoadingFacility) {
      return ModernPageWrapper(
        currentRoute: '/contracts',
        title: 'Contract Templates',
        showSidebar: false,
        onNavigate: (route) {
          ModernNavigationService.navigateToRoute(context, route);
        },
        child: const Center(child: CircularProgressIndicator()),
      );
    }

    final isAllFacilities = _selectedFacilityId == _kAllFacilities || _selectedFacilityId == null;

    return ModernPageWrapper(
      currentRoute: '/contracts',
      title: 'Contract Templates',
      showSidebar: false,
      onNavigate: (route) {
        ModernNavigationService.navigateToRoute(context, route);
      },
      actions: [
        IconButton(
          icon: const Icon(Icons.add),
          onPressed: () => _showCreateTemplateDialog(),
          tooltip: 'Create Template',
        ),
        IconButton(
          icon: const Icon(Icons.library_add),
          onPressed: () => _showAddDefaultTemplatesDialog(),
          tooltip: 'Add default templates',
        ),
      ],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildFacilitySelector(),
          Expanded(
            child: isAllFacilities
                ? _buildAllFacilitiesTemplates()
                : _buildSingleFacilityTemplates(_selectedFacilityId!),
          ),
        ],
      ),
    );
  }

  Widget _buildSingleFacilityTemplates(String facilityId) {
    final templatesAsync = ref.watch(contractTemplatesProvider(facilityId));
    return templatesAsync.when(
      data: (templates) => _buildTemplateList(templates, facilityId: null),
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (error, _) => Center(
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
    );
  }

  Widget _buildAllFacilitiesTemplates() {
    return FutureBuilder<List<FacilityModel>>(
      future: FacilityService.getUserFacilities(),
      builder: (context, facilitySnapshot) {
        if (!facilitySnapshot.hasData) {
          return const Center(child: CircularProgressIndicator());
        }
        final facilities = facilitySnapshot.data!;
        if (facilities.isEmpty) {
          return const Center(child: Text('No facilities found. Please create a facility first.'));
        }
        return _AllFacilitiesTemplateList(facilities: facilities);
      },
    );
  }

  Widget _buildTemplateList(
    List<ContractTemplateModel> templates, {
    required String? facilityId,
    Map<String, String>? facilityNames,
  }) {
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
              'Add default storage facility templates or create your own',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: AppTheme.textSecondary,
              ),
            ),
            const SizedBox(height: 24),
            ElevatedButton.icon(
              onPressed: () => _showAddDefaultTemplatesDialog(),
              icon: const Icon(Icons.library_add),
              label: const Text('Add default templates'),
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
        final facilityLabel = facilityNames?[template.facilityId];
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
                if (facilityLabel != null) ...[
                  const SizedBox(height: 2),
                  Row(
                    children: [
                      Icon(Icons.business, size: 13, color: AppTheme.textSecondary),
                      const SizedBox(width: 4),
                      Text(
                        facilityLabel,
                        style: TextStyle(fontSize: 12, color: AppTheme.textSecondary),
                      ),
                    ],
                  ),
                ],
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
  }

  Widget _buildFacilitySelector() {
    return FutureBuilder<List<FacilityModel>>(
      future: FacilityService.getUserFacilities(),
      builder: (context, snapshot) {
        if (!snapshot.hasData) return const SizedBox.shrink();
        final facilities = snapshot.data!;
        if (facilities.isEmpty) return const SizedBox.shrink();

        // Ensure the current selection is valid
        final selectedId = _selectedFacilityId ?? _kAllFacilities;
        if (selectedId != _kAllFacilities && !facilities.any((f) => f.id == selectedId)) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) setState(() => _selectedFacilityId = _kAllFacilities);
          });
        }
        final effectiveId = (selectedId != _kAllFacilities && facilities.any((f) => f.id == selectedId))
            ? selectedId
            : _kAllFacilities;

        final isAllFacilities = effectiveId == _kAllFacilities;

        return Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              DropdownButtonFormField<String>(
                value: effectiveId,
                decoration: const InputDecoration(
                  labelText: 'Facility',
                  border: OutlineInputBorder(),
                  prefixIcon: Icon(Icons.business),
                ),
                items: [
                  const DropdownMenuItem<String>(
                    value: _kAllFacilities,
                    child: Text('All Facilities'),
                  ),
                  ...facilities.map<DropdownMenuItem<String>>((f) {
                    return DropdownMenuItem<String>(
                      value: f.id,
                      child: Text(f.name),
                    );
                  }),
                ],
                onChanged: (value) {
                  if (value != null && mounted) {
                    setState(() => _selectedFacilityId = value);
                    // Sync global picker: clear it when "All" is chosen, set it otherwise
                    if (value == _kAllFacilities) {
                      ref.read(selectedFacilityProvider.notifier).state = null;
                    } else {
                      final picked = facilities.firstWhere((f) => f.id == value);
                      ref.read(selectedFacilityProvider.notifier).state = picked;
                    }
                  }
                },
              ),
              const SizedBox(height: 4),
              Text(
                isAllFacilities
                    ? 'Showing templates across all your facilities.'
                    : 'Templates you create here appear only when creating contracts for this facility.',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        );
      },
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

  void _showAddDefaultTemplatesDialog() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Add default templates'),
        content: const SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Add standard storage facility contract templates for this facility:',
                style: TextStyle(fontWeight: FontWeight.w500),
              ),
              SizedBox(height: 12),
              _BulletItem(text: 'Self-storage / mini storage rental agreement'),
              _BulletItem(text: 'Vehicle, boat & RV storage rental agreement'),
              _BulletItem(text: 'Addendum to rental agreement'),
              _BulletItem(text: 'Lien waiver / release of lien'),
              SizedBox(height: 12),
              Text(
                'You can edit any template after adding. PDFs can be attached when creating contracts from these templates.',
                style: TextStyle(fontSize: 12, color: AppTheme.textSecondary),
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
            onPressed: () {
              Navigator.of(context).pop();
              _createDefaultTemplates();
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: AppTheme.primaryBlueDark,
              foregroundColor: AppTheme.textOnDark,
            ),
            child: const Text('Add default templates'),
          ),
        ],
      ),
    );
  }

  void _showCreateTemplateDialog() {
    if (_selectedFacilityId == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Please select a facility first'),
          backgroundColor: AppTheme.error,
        ),
      );
      return;
    }
    context.push('${AppRoute.contractTemplatesCreate}?facilityId=${_selectedFacilityId}');
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
      // Self-storage / mini storage rental agreement
      await ContractService.createContractTemplate(
        facilityId: _selectedFacilityId!,
        name: 'Self-Storage / Mini Storage Rental Agreement',
        description: 'Standard rental agreement for self-storage and mini storage units',
        content: _getDefaultStorageAgreementContent(),
        type: ContractType.storage,
      );

      // Vehicle, boat & RV storage rental agreement
      await ContractService.createContractTemplate(
        facilityId: _selectedFacilityId!,
        name: 'Vehicle, Boat & RV Storage Rental Agreement',
        description: 'Rental agreement for vehicle, boat, and RV parking or storage spaces',
        content: _getDefaultVehicleStorageContent(),
        type: ContractType.rental,
      );

      // Addendum to rental agreement
      await ContractService.createContractTemplate(
        facilityId: _selectedFacilityId!,
        name: 'Addendum to Rental Agreement',
        description: 'Addendum to modify or add terms to an existing rental agreement',
        content: _getDefaultAddendumContent(),
        type: ContractType.custom,
      );

      // Lien waiver / release of lien
      await ContractService.createContractTemplate(
        facilityId: _selectedFacilityId!,
        name: 'Lien Waiver / Release of Lien',
        description: 'Release of lien upon payment or settlement of charges',
        content: _getDefaultLienWaiverContent(),
        type: ContractType.custom,
      );

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Default templates added successfully. You can edit them or attach PDFs when creating contracts.'),
            backgroundColor: AppTheme.success,
          ),
        );
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

  String _getDefaultVehicleStorageContent() {
    return '''
# Vehicle, Boat & RV Storage Rental Agreement

## Parties
This agreement is entered into between:
- **Facility Owner**: [Facility Name]
- **Tenant**: [Tenant Name]

## Space and Use
- **Space type**: [Parking space / Covered storage / Outdoor lot]
- **Intended use**: [Vehicle / Boat / RV / Other: ___________]
- **Description**: [Make, model, year, license/ID if applicable]

## Terms and Conditions

1. **Rental Period**: This agreement is effective from [Start Date] to [End Date].

2. **Monthly Rent**: The monthly rental fee is \$[Amount] due on the [Day] of each month.

3. **Security Deposit**: A security deposit of \$[Amount] is required.

4. **Access**: Tenant will be provided with [gate code / key / fob] for access during [access hours].

5. **Condition of space**: Tenant accepts the space in its current condition. No modifications without written approval.

6. **Prohibited**: No living in the vehicle/RV on premises; no repairs involving fluids or hazardous materials on site unless permitted in writing.

7. **Liability**: Facility is not responsible for damage to stored vehicles, boats, or RVs from theft, weather, or other causes except as required by law.

8. **Termination**: Either party may terminate with [30] days written notice. Prorated refund may apply per facility policy.

## Signatures

By signing below, both parties agree to the terms above.

**Facility Owner**: _________________ Date: ___________

**Tenant**: _________________ Date: ___________
''';
  }

  String _getDefaultAddendumContent() {
    return '''
# Addendum to Rental Agreement

## Reference
This addendum modifies or adds to the rental agreement dated [Original Agreement Date] between [Facility Name] and [Tenant Name] for [Unit/Space description].

## Effective Date
This addendum is effective as of [Addendum Date].

## Additional or Modified Terms

[Describe the specific changes or additional terms. Examples:]
- Change in monthly rent: \$[New Amount] effective [Date]
- Change in access hours: [New hours]
- Additional occupant or authorized user: [Name]
- Special provisions: [Description]

## Acknowledgment
Both parties agree that this addendum is part of the original agreement. All other terms of the original agreement remain in effect unless expressly modified above.

**Facility Owner**: _________________ Date: ___________

**Tenant**: _________________ Date: ___________
''';
  }

  String _getDefaultLienWaiverContent() {
    return '''
# Lien Waiver / Release of Lien

## Parties
- **Facility**: [Facility Name]
- **Tenant / Customer**: [Tenant Name]
- **Unit/Space**: [Unit number or space description]

## Release
The facility hereby releases and waives any lien, claim, or right to retain possession of the property stored in the above unit/space, and any claim for unpaid rent, fees, or charges related to such storage, as of [Date of Release].

## Condition of Release
This release is given in consideration of:
- [ ] Payment in full of all amounts due
- [ ] Settlement agreement dated [Date]
- [ ] Other: [Describe]

## Certification
The facility certifies that upon execution of this waiver, the tenant is entitled to full access to and removal of all stored property, subject to any applicable law or court order.

**Facility Authorized Signatory**: _________________ Date: ___________

**Tenant**: _________________ Date: ___________
''';
  }

  void _viewTemplate(ContractTemplateModel template) {
    showDialog(
      context: context,
      builder: (context) => Dialog(
        insetPadding: const EdgeInsets.all(16),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 600, maxHeight: 700),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 16, 8, 0),
                child: Row(
                  children: [
                    Expanded(child: Text(template.name, style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold))),
                    IconButton(icon: const Icon(Icons.close), onPressed: () => Navigator.of(context).pop()),
                  ],
                ),
              ),
              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(template.description, style: Theme.of(context).textTheme.bodyMedium),
                      const SizedBox(height: 12),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          Chip(label: Text(template.type.name.toUpperCase()), backgroundColor: AppTheme.primaryBlue.withOpacity(0.1)),
                          if (template.fileUrl != null && template.fileUrl!.isNotEmpty)
                            Chip(avatar: const Icon(Icons.picture_as_pdf, size: 16), label: const Text('PDF attached'), backgroundColor: AppTheme.success.withOpacity(0.1)),
                          Chip(label: Text('${template.signers.length} signers')),
                          if (template.signaturePlaceholders.isNotEmpty)
                            Chip(label: Text('${template.signaturePlaceholders.length} fields configured')),
                        ],
                      ),
                      if (template.fileUrl != null && template.fileUrl!.isNotEmpty) ...[
                        const SizedBox(height: 16),
                        const Divider(),
                        const SizedBox(height: 8),
                        Text('PDF Contract', style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold)),
                        const SizedBox(height: 8),
                        OutlinedButton.icon(
                          onPressed: () {
                            final url = Uri.tryParse(template.fileUrl!);
                            if (url != null) launchUrl(url, mode: LaunchMode.externalApplication);
                          },
                          icon: const Icon(Icons.open_in_new, size: 18),
                          label: const Text('View PDF'),
                        ),
                      ],
                      if (template.signaturePlaceholders.isNotEmpty) ...[
                        const SizedBox(height: 16),
                        const Divider(),
                        const SizedBox(height: 8),
                        Text('Configured Signature Fields', style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold)),
                        const SizedBox(height: 8),
                        ...template.signaturePlaceholders.map((p) => Padding(
                          padding: const EdgeInsets.only(bottom: 6),
                          child: Row(
                            children: [
                              Icon(
                                p.fieldType == SignatureFieldType.signature ? Icons.draw :
                                p.fieldType == SignatureFieldType.date ? Icons.event :
                                p.fieldType == SignatureFieldType.name ? Icons.person :
                                p.fieldType == SignatureFieldType.storageUnit ? Icons.garage :
                                p.fieldType == SignatureFieldType.initials ? Icons.text_fields :
                                Icons.short_text,
                                size: 18, color: AppTheme.primaryBlue,
                              ),
                              const SizedBox(width: 8),
                              Text(p.label ?? p.fieldType.displayName, style: const TextStyle(fontSize: 14)),
                              const Spacer(),
                              Text('Page ${p.page}', style: TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
                            ],
                          ),
                        )),
                      ],
                      if (template.content.isNotEmpty) ...[
                        const SizedBox(height: 16),
                        const Divider(),
                        const SizedBox(height: 8),
                        Text('Content Preview', style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold)),
                        const SizedBox(height: 8),
                        Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: AppTheme.backgroundLight,
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Text(
                            template.content.length > 500
                                ? '${template.content.substring(0, 500)}...'
                                : template.content,
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _editTemplate(ContractTemplateModel template) {
    context.push(AppRoute.contractTemplatesEdit, extra: template).then((_) {
      if (mounted && _selectedFacilityId != null) {
        ref.invalidate(contractTemplatesProvider(_selectedFacilityId!));
      }
    });
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

    final facilityId = template.facilityId.isNotEmpty ? template.facilityId : _selectedFacilityId;
    if (confirm == true && facilityId != null && facilityId != _kAllFacilities) {
      try {
        await ContractService.deleteContractTemplate(
          facilityId: facilityId,
          templateId: template.id,
        );
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Template deleted successfully'),
              backgroundColor: AppTheme.success,
            ),
          );
          ref.invalidate(contractTemplatesProvider(facilityId));
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

/// Loads templates from every facility and displays them in a combined list.
class _AllFacilitiesTemplateList extends ConsumerWidget {
  final List<FacilityModel> facilities;

  const _AllFacilitiesTemplateList({required this.facilities});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final asyncValues = facilities
        .map((f) => ref.watch(contractTemplatesProvider(f.id)))
        .toList();

    final isLoading = asyncValues.any((a) => a.isLoading);
    final hasError = asyncValues.any((a) => a.hasError);

    if (isLoading) return const Center(child: CircularProgressIndicator());
    if (hasError) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.error, size: 64, color: AppTheme.error),
            const SizedBox(height: 16),
            const Text('Error loading templates'),
          ],
        ),
      );
    }

    final facilityNames = {for (final f in facilities) f.id: f.name};
    final allTemplates = <ContractTemplateModel>[];
    for (int i = 0; i < facilities.length; i++) {
      final templates = asyncValues[i].value ?? [];
      allTemplates.addAll(templates);
    }

    if (allTemplates.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.description, size: 64, color: AppTheme.textTertiary),
            const SizedBox(height: 16),
            Text('No Templates Yet', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 8),
            Text(
              'Select a specific facility and add default templates or create your own.',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: AppTheme.textSecondary),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: allTemplates.length,
      itemBuilder: (context, index) {
        final template = allTemplates[index];
        final facilityLabel = facilityNames[template.facilityId];
        return Card(
          margin: const EdgeInsets.only(bottom: 12),
          child: ListTile(
            leading: Icon(
              _iconForType(template.type),
              color: AppTheme.primaryBlueDark,
            ),
            title: Text(
              template.name,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            subtitle: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (facilityLabel != null) ...[
                  const SizedBox(height: 2),
                  Row(
                    children: [
                      Icon(Icons.business, size: 13, color: AppTheme.textSecondary),
                      const SizedBox(width: 4),
                      Text(
                        facilityLabel,
                        style: TextStyle(fontSize: 12, color: AppTheme.textSecondary),
                      ),
                    ],
                  ),
                ],
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
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _viewTemplate(context, template),
          ),
        );
      },
    );
  }

  IconData _iconForType(ContractType type) {
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

  void _viewTemplate(BuildContext context, ContractTemplateModel template) {
    showDialog(
      context: context,
      builder: (context) => Dialog(
        insetPadding: const EdgeInsets.all(16),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 600, maxHeight: 700),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 16, 8, 0),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        template.name,
                        style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold),
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.close),
                      onPressed: () => Navigator.of(context).pop(),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(template.description, style: Theme.of(context).textTheme.bodyMedium),
                      const SizedBox(height: 12),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          Chip(
                            label: Text(template.type.name.toUpperCase()),
                            backgroundColor: AppTheme.primaryBlue.withOpacity(0.1),
                          ),
                          if (template.fileUrl != null && template.fileUrl!.isNotEmpty)
                            Chip(
                              avatar: const Icon(Icons.picture_as_pdf, size: 16),
                              label: const Text('PDF attached'),
                              backgroundColor: AppTheme.success.withOpacity(0.1),
                            ),
                          Chip(label: Text('${template.signers.length} signers')),
                        ],
                      ),
                      if (template.content.isNotEmpty) ...[
                        const SizedBox(height: 16),
                        const Divider(),
                        const SizedBox(height: 8),
                        Text(
                          'Content Preview',
                          style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold),
                        ),
                        const SizedBox(height: 8),
                        Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: AppTheme.backgroundLight,
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Text(
                            template.content.length > 500
                                ? '${template.content.substring(0, 500)}...'
                                : template.content,
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

