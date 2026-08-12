import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:go_router/go_router.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import '../models/contract_model.dart';
import '../models/contract_template_model.dart';
import '../models/tenant_model.dart';
import '../models/dnr_model.dart';
import '../providers/contract_provider.dart';
import '../providers/auth_provider.dart';
import '../providers/facility_provider.dart';
import '../services/facility_service.dart';
import '../services/tenant_service.dart';
import '../services/contract_service.dart';
import '../services/contract_send_service.dart';
import '../services/dnr_service.dart';
import '../services/audit_service.dart';
import '../services/compliance_service.dart';
import '../router/app_route.dart';
import '../theme/app_theme.dart';
import '../widgets/keyboard_scrollable.dart';
import '../widgets/modern_page_wrapper.dart';
import '../widgets/signature_field_configurator.dart';
import '../services/modern_navigation_service.dart';
import 'package:url_launcher/url_launcher.dart';

class ContractCreationScreen extends ConsumerStatefulWidget {
  final String? facilityId;
  final String? tenantId; // Optional: pre-selects a tenant
  final ContractModel? contract; // Optional: if provided, screen is in edit mode
  
  const ContractCreationScreen({
    super.key,
    this.facilityId,
    this.tenantId,
    this.contract,
  });

  @override
  ConsumerState<ContractCreationScreen> createState() => _ContractCreationScreenState();
  
  bool get isEditMode => contract != null;
}

class _SignerAssignment {
  final String signerId;
  final String label;
  final String role;
  final String name;
  final String? email;
  final String? phone;

  const _SignerAssignment({
    required this.signerId,
    required this.label,
    required this.role,
    required this.name,
    this.email,
    this.phone,
  });

  _SignerAssignment copyWith({
    String? label,
    String? role,
    String? name,
    String? email,
    String? phone,
  }) {
    return _SignerAssignment(
      signerId: signerId,
      label: label ?? this.label,
      role: role ?? this.role,
      name: name ?? this.name,
      email: email ?? this.email,
      phone: phone ?? this.phone,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'signerId': signerId,
      'label': label,
      'role': role,
      'name': name,
      if (email != null) 'email': email,
      if (phone != null) 'phone': phone,
    };
  }
}

class _ContractCreationScreenState extends ConsumerState<ContractCreationScreen> {
  static final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final _formKey = GlobalKey<FormState>();
  final _titleController = TextEditingController();
  final _descriptionController = TextEditingController();
  final _notesController = TextEditingController();
  
  ContractType _selectedType = ContractType.lease;
  String? _selectedFacilityId;
  String? _selectedTenantId;
  String? _selectedTemplateId;
  ContractTemplateModel? _activeTemplate;
  TenantModel? _selectedTenantModel;
  Map<String, _SignerAssignment> _signerAssignments = {};
  DateTime? _expiresAt;
  bool _isLoading = false;
  String? _errorMessage;
  bool _dnrOverride = false;
  List<DNRModel>? _dnrMatches;
  
  // File upload state
  PlatformFile? _selectedFile;
  String? _uploadedFileUrl;
  String? _uploadedFileName;
  bool _isUploading = false;
  /// Contracts with PDFs in this facility (for reuse dropdown)
  List<ContractModel> _contractsWithPdf = [];
  bool _loadingContractsWithPdf = false;
  /// 0.0..1.0 or null when not uploading
  double? _uploadProgress;
  
  // Compliance state
  bool _hasAcceptedTerms = false;
  bool _rightsAttestationChecked = false;
  bool _isLicensedForm = false;
  bool _termsModalShown = false;

  // Custom signature field configuration (when PDF is present)
  List<SignaturePlaceholder>? _customSignaturePlaceholders;

  @override
  void initState() {
    super.initState();
    _selectedFacilityId = widget.facilityId ?? widget.contract?.facilityId;

    // Pre-select tenant when navigating from tenant detail
    if (widget.tenantId != null && widget.tenantId!.isNotEmpty) {
      _selectedTenantId = widget.tenantId;
      if (_selectedFacilityId != null && _selectedFacilityId!.isNotEmpty) {
        _loadTenant(_selectedFacilityId!, widget.tenantId!);
      }
    }
    
    // If in edit mode, populate fields with contract data
    if (widget.isEditMode && widget.contract != null) {
      final contract = widget.contract!;
      _titleController.text = contract.title;
      _descriptionController.text = contract.description ?? '';
      _notesController.text = contract.notes ?? '';
      _selectedType = contract.type;
      _selectedTenantId = contract.tenantId;
      _expiresAt = contract.expiresAt;
      _uploadedFileUrl = contract.fileUrl;
      
      // Load tenant model if tenant ID is available
      if (contract.tenantId.isNotEmpty && contract.facilityId.isNotEmpty) {
        _loadTenant(contract.facilityId, contract.tenantId);
      }
    }
    
    _loadInitialData();
    _checkTermsAcceptance();
  }
  
  Future<void> _checkTermsAcceptance() async {
    if (_selectedFacilityId == null) return;
    
    try {
      final hasAccepted = await ComplianceService.hasAcceptedTerms(_selectedFacilityId!);
      if (mounted) {
        setState(() {
          _hasAcceptedTerms = hasAccepted;
        });
        
        // Show terms modal if not accepted
        if (!hasAccepted && !_termsModalShown) {
          _termsModalShown = true;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            _showTermsAcceptanceModal();
          });
        }
      }
    } catch (e) {
      if (kDebugMode) {
        print('⚠️ Error checking terms acceptance: $e');
      }
    }
  }
  
  Future<void> _loadTenant(String facilityId, String tenantId) async {
    try {
      final tenant = await TenantService.getTenantById(facilityId, tenantId);
      if (tenant != null && mounted) {
        setState(() {
          _selectedTenantModel = tenant;
        });
      }
    } catch (e) {
      if (kDebugMode) {
        print('⚠️ Error loading tenant: $e');
      }
    }
  }

  @override
  void dispose() {
    _titleController.dispose();
    _descriptionController.dispose();
    _notesController.dispose();
    // Note: Cannot use ref in dispose() as it's already unmounted
    // The provider state will be automatically cleaned up
    super.dispose();
  }

  Future<void> _loadInitialData() async {
    if (_selectedFacilityId == null) {
      try {
        final uid = ref.read(authStateProvider).maybeWhen(data: (u) => u?.uid, orElse: () => null);
        final facilities = uid == null
            ? await FacilityService.getUserFacilities()
            : await ref.read(userFacilitiesProvider(uid).future);
        if (facilities.isNotEmpty) {
          setState(() {
            _selectedFacilityId = facilities.first.id;
          });
          _loadContractsWithPdf();
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
    } else {
      _loadContractsWithPdf();
    }
  }

  Future<void> _loadContractsWithPdf() async {
    if (_selectedFacilityId == null) return;
    setState(() => _loadingContractsWithPdf = true);
    try {
      final contracts = await ContractService.getContractsForFacility(_selectedFacilityId!);
      final withPdf = contracts.where((c) => c.fileUrl != null && c.fileUrl!.isNotEmpty).toList();
      if (mounted) {
        setState(() {
          _contractsWithPdf = withPdf;
          _loadingContractsWithPdf = false;
        });
      }
    } catch (e) {
      if (kDebugMode) print('⚠️ Error loading contracts with PDF: $e');
      if (mounted) {
        setState(() {
          _contractsWithPdf = [];
          _loadingContractsWithPdf = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_isUploading,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop && _isUploading && context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Upload in progress. Please wait for it to finish.'),
              duration: Duration(seconds: 3),
            ),
          );
        }
      },
      child: KeyboardScrollable(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16.0),
          child: Form(
            key: _formKey,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
              // Basic Information Section
              _buildSectionHeader('Basic Information'),
              const SizedBox(height: 16),
              
              // Title
              TextFormField(
                controller: _titleController,
                decoration: const InputDecoration(
                  labelText: 'Contract Title',
                  border: OutlineInputBorder(),
                  prefixIcon: Icon(Icons.title),
                ),
                validator: (value) {
                  if (value == null || value.trim().isEmpty) {
                    return 'Please enter a contract title';
                  }
                  return null;
                },
              ),
              const SizedBox(height: 16),
              
              // Description
              TextFormField(
                controller: _descriptionController,
                decoration: const InputDecoration(
                  labelText: 'Description',
                  border: OutlineInputBorder(),
                  prefixIcon: Icon(Icons.description),
                ),
                maxLines: 3,
                validator: (value) {
                  if (value == null || value.trim().isEmpty) {
                    return 'Please enter a description';
                  }
                  return null;
                },
              ),
              const SizedBox(height: 16),
              
              // Contract Type
              DropdownButtonFormField<ContractType>(
                value: _selectedType,
                decoration: const InputDecoration(
                  labelText: 'Contract Type',
                  border: OutlineInputBorder(),
                  prefixIcon: Icon(Icons.category),
                ),
                items: ContractType.values.map((type) {
                  return DropdownMenuItem(
                    value: type,
                    child: Text(type.displayName),
                  );
                }).toList(),
                onChanged: (value) {
                  if (value != null && mounted) {
                    setState(() {
                      _selectedType = value;
                    });
                  }
                },
              ),
              const SizedBox(height: 24),
              
              // Facility and Tenant Selection
              _buildSectionHeader('Parties'),
              const SizedBox(height: 16),
              
              // Facility Selection
              _buildFacilitySelector(),
              const SizedBox(height: 16),
              
              // Tenant Selection
              _buildTenantSelector(),
              const SizedBox(height: 24),
              
              // Template Selection or File Upload
              _buildSectionHeader('Contract Document'),
              const SizedBox(height: 16),
              
              // Option 1: Use Template
              _buildTemplateSelector(),
              const SizedBox(height: 16),
              
              // Option 2: Upload PDF File
              _buildFileUploadSection(),
              const SizedBox(height: 24),
              
              // Compliance Section (only shown when file is selected)
              if (_selectedFile != null || _uploadedFileUrl != null) ...[
                _buildComplianceSection(),
                const SizedBox(height: 24),
                _buildSignatureFieldConfigurator(),
                const SizedBox(height: 24),
              ],
              
              if (_activeTemplate != null) ...[
                _buildSignerSection(),
                const SizedBox(height: 24),
              ],
              
              // Additional Information
              _buildSectionHeader('Additional Information'),
              const SizedBox(height: 16),
              
              // Expiration Date
              _buildExpirationDateSelector(),
              const SizedBox(height: 16),
              
              // Notes
              TextFormField(
                controller: _notesController,
                decoration: const InputDecoration(
                  labelText: 'Notes (Optional)',
                  border: OutlineInputBorder(),
                  prefixIcon: Icon(Icons.note),
                ),
                maxLines: 3,
              ),
              const SizedBox(height: 32),
              
              // Error Message
              if (_errorMessage != null)
                Container(
                  padding: const EdgeInsets.all(12),
                  margin: const EdgeInsets.only(bottom: 16),
                  decoration: BoxDecoration(
                    color: AppTheme.error.withOpacity(0.1),
                    border: Border.all(color: AppTheme.error),
                    borderRadius: BorderRadius.circular(8),
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
              
              // Action Buttons
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: (_isLoading || _isUploading) ? null : () => Navigator.of(context).pop(),
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 16),
                      ),
                      child: const Text('Cancel'),
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: ElevatedButton(
                      onPressed: _isLoading ? null : _createContract,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppTheme.primaryBlueDark,
                        foregroundColor: AppTheme.textOnDark,
                        padding: const EdgeInsets.symmetric(vertical: 16),
                      ),
                      child: _isLoading
                          ? const SizedBox(
                              height: 20,
                              width: 20,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                valueColor: AlwaysStoppedAnimation<Color>(AppTheme.textOnDark),
                              ),
                            )
                          : Text(widget.isEditMode ? 'Update Contract' : 'Create Contract'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    ),
    );
  }

  ContractTemplateModel? _findTemplateById(List<ContractTemplateModel> templates, String? id) {
    if (id == null) return null;
    for (final template in templates) {
      if (template.id == id) {
        return template;
      }
    }
    return null;
  }

  void _handleTemplateSelection(String? value, List<ContractTemplateModel> templates) {
    if (!mounted) return;
    final template = _findTemplateById(templates, value);
    setState(() {
      _selectedTemplateId = value;
      _activeTemplate = template;
      if (template != null) {
        if (_titleController.text.trim().isEmpty) _titleController.text = template.name;
        if (_descriptionController.text.trim().isEmpty) _descriptionController.text = template.description;
        if (template.fileUrl != null && template.fileUrl!.isNotEmpty) {
          _uploadedFileUrl = template.fileUrl;
          _uploadedFileName = '${template.name} (template PDF)';
          _selectedFile = null;
          if (template.signaturePlaceholders.isNotEmpty) {
            _customSignaturePlaceholders = template.signaturePlaceholders;
          }
        }
      }
    });
    _syncSignerAssignments();
  }

  void _syncSignerAssignments() {
    if (!mounted) return;
    final template = _activeTemplate;
    if (template == null) {
      setState(() {
        _signerAssignments = {};
      });
      return;
    }

    final updatedAssignments = <String, _SignerAssignment>{};
    for (final signer in template.signers) {
      updatedAssignments[signer.id] = _buildAssignmentForSigner(signer, _signerAssignments[signer.id]);
    }

    setState(() {
      _signerAssignments = updatedAssignments;
    });
  }

  _SignerAssignment _buildAssignmentForSigner(TemplateSigner signer, _SignerAssignment? existing) {
    final resolvedName = _resolveSignerName(signer, existing) ?? '';
    final resolvedEmail = _resolveSignerEmail(signer, existing);
    final resolvedPhone = _resolveSignerPhone(signer, existing);

    final base = existing ??
        _SignerAssignment(
          signerId: signer.id,
          label: signer.label,
          role: signer.role,
          name: resolvedName,
          email: resolvedEmail,
          phone: resolvedPhone,
        );

    return base.copyWith(
      label: signer.label,
      role: signer.role,
      name: resolvedName,
      email: signer.requiresEmail ? (resolvedEmail ?? '') : resolvedEmail,
      phone: signer.requiresPhone ? (resolvedPhone ?? '') : resolvedPhone,
    );
  }

  String? _resolveSignerName(TemplateSigner signer, _SignerAssignment? existing) {
    final existingName = existing?.name.trim();
    if (existingName != null && existingName.isNotEmpty) {
      return existing!.name;
    }

    if (signer.isTenantSigner && _selectedTenantModel != null) {
      final tenantName = _selectedTenantModel!.name.trim();
      if (tenantName.isNotEmpty) {
        return tenantName;
      }
    }

    if (signer.isFacilitySigner) {
      final user = ref.read(authStateProvider).value;
      final displayName = user?.displayName?.trim();
      if (displayName != null && displayName.isNotEmpty) {
        return displayName;
      }
      final userEmail = user?.email?.trim();
      if (userEmail != null && userEmail.isNotEmpty) {
        return userEmail;
      }
    }

    final metadataName = signer.metadata?['defaultName'] as String?;
    if (metadataName != null && metadataName.trim().isNotEmpty) {
      return metadataName;
    }

    return existing?.name;
  }

  String? _resolveSignerEmail(TemplateSigner signer, _SignerAssignment? existing) {
    final existingEmail = existing?.email?.trim();
    if (existingEmail != null && existingEmail.isNotEmpty) {
      return existing!.email;
    }

    if (signer.isTenantSigner && _selectedTenantModel?.email != null) {
      final tenantEmail = _selectedTenantModel!.email.trim();
      if (tenantEmail.isNotEmpty) {
        return tenantEmail;
      }
    }

    if (signer.isFacilitySigner) {
      final userEmail = ref.read(authStateProvider).value?.email?.trim();
      if (userEmail != null && userEmail.isNotEmpty) {
        return userEmail;
      }
    }

    final metadataEmail = signer.metadata?['defaultEmail'] as String?;
    if (metadataEmail != null && metadataEmail.trim().isNotEmpty) {
      return metadataEmail;
    }

    return existing?.email;
  }

  String? _resolveSignerPhone(TemplateSigner signer, _SignerAssignment? existing) {
    final existingPhone = existing?.phone?.trim();
    if (existingPhone != null && existingPhone.isNotEmpty) {
      return existing!.phone;
    }

    if (signer.isTenantSigner && _selectedTenantModel?.phone != null) {
      final tenantPhone = _selectedTenantModel!.phone.trim();
      if (tenantPhone.isNotEmpty) {
        return tenantPhone;
      }
    }

    final metadataPhone = signer.metadata?['defaultPhone'] as String?;
    if (metadataPhone != null && metadataPhone.trim().isNotEmpty) {
      return metadataPhone;
    }

    return existing?.phone;
  }

  void _updateSignerAssignment(
    String signerId, {
    String? name,
    String? email,
    String? phone,
  }) {
    if (!mounted) return;
    final current = _signerAssignments[signerId];
    if (current == null) return;

    setState(() {
      final updated = Map<String, _SignerAssignment>.from(_signerAssignments);
      updated[signerId] = current.copyWith(
        name: name,
        email: email,
        phone: phone,
      );
      _signerAssignments = updated;
    });
  }

  Widget _buildSignerSection() {
    final template = _activeTemplate;
    if (template == null) {
      return const SizedBox.shrink();
    }

    if (template.signers.isEmpty) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildSectionHeader('Signers & E-Signature Fields'),
          const SizedBox(height: 8),
          Text(
            'This template does not define any signers. You can still attach documents manually after creating the contract.',
            style: Theme.of(context).textTheme.bodyMedium,
          ),
        ],
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildSectionHeader('Signers & E-Signature Fields'),
        const SizedBox(height: 12),
        ...template.signers.map((signer) {
          final assignment = _signerAssignments[signer.id] ?? _buildAssignmentForSigner(signer, null);
          final fields = template.signaturePlaceholders
              .where((placeholder) => placeholder.signerId == signer.id)
              .toList();

          return Card(
            margin: const EdgeInsets.only(bottom: 12),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    signer.label,
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Role: ${signer.role[0].toUpperCase()}${signer.role.substring(1)}',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  const SizedBox(height: 16),
                  TextFormField(
                    key: ValueKey('${signer.id}-name-${assignment.name}'),
                    initialValue: assignment.name,
                    decoration: const InputDecoration(
                      labelText: 'Signer Name',
                      border: OutlineInputBorder(),
                      prefixIcon: Icon(Icons.person_outline),
                    ),
                    onChanged: (value) => _updateSignerAssignment(signer.id, name: value),
                  ),
                  const SizedBox(height: 12),
                  if (signer.requiresEmail)
                    TextFormField(
                      key: ValueKey('${signer.id}-email-${assignment.email ?? ''}'),
                      initialValue: assignment.email,
                      decoration: const InputDecoration(
                        labelText: 'Email',
                        border: OutlineInputBorder(),
                        prefixIcon: Icon(Icons.email_outlined),
                      ),
                      keyboardType: TextInputType.emailAddress,
                      onChanged: (value) => _updateSignerAssignment(signer.id, email: value),
                    ),
                  if (signer.requiresEmail) const SizedBox(height: 12),
                  if (signer.requiresPhone)
                    TextFormField(
                      key: ValueKey('${signer.id}-phone-${assignment.phone ?? ''}'),
                      initialValue: assignment.phone,
                      decoration: const InputDecoration(
                        labelText: 'Phone',
                        border: OutlineInputBorder(),
                        prefixIcon: Icon(Icons.phone_outlined),
                      ),
                      keyboardType: TextInputType.phone,
                      onChanged: (value) => _updateSignerAssignment(signer.id, phone: value),
                    ),
                  if (signer.requiresPhone) const SizedBox(height: 12),
                  if (fields.isNotEmpty) ...[
                    Text(
                      'Signature Fields',
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 4,
                      children: fields.map((field) {
                        final label = field.label ?? field.fieldType.displayName;
                        return Chip(
                          avatar: Icon(
                            _iconForSignatureFieldType(field.fieldType),
                            size: 18,
                          ),
                          label: Text('$label • Page ${field.page}'),
                        );
                      }).toList(),
                    ),
                  ] else ...[
                    Text(
                      'No signature placeholders defined for this signer in the template.',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(color: AppTheme.textSecondary),
                    ),
                  ],
                ],
              ),
            ),
          );
        }),
      ],
    );
  }

  IconData _iconForSignatureFieldType(SignatureFieldType type) {
    switch (type) {
      case SignatureFieldType.signature:
        return Icons.draw;
      case SignatureFieldType.initials:
        return Icons.text_fields;
      case SignatureFieldType.date:
        return Icons.event;
      case SignatureFieldType.text:
        return Icons.short_text;
      case SignatureFieldType.storageUnit:
        return Icons.garage;
      case SignatureFieldType.name:
        return Icons.person;
    }
  }

  String? _validateSignerAssignments(ContractTemplateModel template) {
    for (final signer in template.signers) {
      final assignment = _signerAssignments[signer.id];
      if (assignment == null) {
        return 'Missing signer information for ${signer.label}.';
      }

      if (assignment.name.trim().isEmpty) {
        return 'Enter a signer name for ${signer.label}.';
      }

      if (signer.requiresEmail && (assignment.email == null || assignment.email!.trim().isEmpty)) {
        return 'Enter an email address for ${signer.label}.';
      }

      if (signer.requiresPhone && (assignment.phone == null || assignment.phone!.trim().isEmpty)) {
        return 'Enter a phone number for ${signer.label}.';
      }
    }
    return null;
  }

  Map<String, dynamic> _buildCustomFieldsForTemplate(ContractTemplateModel template) {
    final placeholders = _customSignaturePlaceholders ?? template.signaturePlaceholders;
    return {
      'signers': _signerAssignments.map((key, value) => MapEntry(key, value.toMap())),
      'signaturePlaceholders': placeholders.map((field) => field.toMap()).toList(),
      'templateSigners': template.signers.map((signer) => signer.toMap()).toList(),
    };
  }

  Widget _buildSignatureFieldConfigurator() {
    return ExpansionTile(
      title: Row(
        children: [
          Icon(Icons.edit_location_alt, color: AppTheme.primaryBlue, size: 20),
          const SizedBox(width: 8),
          Text(
            'Configure signature fields',
            style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
          ),
        ],
      ),
      subtitle: Text(
        'Choose where "Sign your name", "Sign the date", "Storage unit number", etc. appear on the PDF',
        style: Theme.of(context).textTheme.bodySmall?.copyWith(color: AppTheme.textSecondary),
      ),
      children: [
        Padding(
          padding: const EdgeInsets.all(16),
          child: SignatureFieldConfigurator(
            pdfBytes: _selectedFile?.bytes != null ? Uint8List.fromList(_selectedFile!.bytes!) : null,
            pdfUrl: _uploadedFileUrl,
            initialPlaceholders: _customSignaturePlaceholders ?? _activeTemplate?.signaturePlaceholders ?? [],
            tenantSignerId: _activeTemplate?.signers.any((s) => s.isTenantSigner) == true
                ? _activeTemplate!.signers.firstWhere((s) => s.isTenantSigner).id
                : 'tenantPrimary',
            onPlaceholdersChanged: (placeholders) {
              setState(() => _customSignaturePlaceholders = placeholders);
            },
          ),
        ),
      ],
    );
  }

  Widget _buildSectionHeader(String title) {
    return Text(
      title,
      style: Theme.of(context).textTheme.titleLarge?.copyWith(
        fontWeight: FontWeight.bold,
        color: AppTheme.primaryBlueDark,
      ),
    );
  }

  Widget _buildFacilitySelector() {
    return FutureBuilder<List<dynamic>>(
      future: FacilityService.getUserFacilities(),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(
            child: SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          );
        }

        if (snapshot.hasError) {
          return Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: AppTheme.error.withOpacity(0.1),
              border: Border.all(color: AppTheme.error),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              children: [
                Icon(Icons.error, color: AppTheme.error),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Error loading facilities: ${snapshot.error}',
                    style: TextStyle(color: AppTheme.error),
                  ),
                ),
              ],
            ),
          );
        }

        if (!snapshot.hasData || snapshot.data!.isEmpty) {
          return Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: AppTheme.warning.withOpacity(0.1),
              border: Border.all(color: AppTheme.warning),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              children: [
                Icon(Icons.business, color: AppTheme.warning),
                const SizedBox(width: 8),
                const Expanded(
                  child: Text('No facilities found. Create a facility first.'),
                ),
              ],
            ),
          );
        }

        final facilities = snapshot.data!;
        
        return DropdownButtonFormField<String>(
          value: _selectedFacilityId,
          decoration: const InputDecoration(
            labelText: 'Facility',
            border: OutlineInputBorder(),
            prefixIcon: Icon(Icons.business),
          ),
          selectedItemBuilder: (context) => facilities
              .map((f) => Text(
                    f.name,
                    style: AppTheme.dropdownItemTextStyle.copyWith(
                      color: Theme.of(context).colorScheme.onSurface,
                    ),
                    overflow: TextOverflow.ellipsis,
                    maxLines: 1,
                  ))
              .toList(),
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
                _selectedTenantId = null; // Reset tenant selection
                _selectedTenantModel = null;
                _selectedFile = null;
                _uploadedFileUrl = null;
                _uploadedFileName = null;
                _customSignaturePlaceholders = null;
              });
              _syncSignerAssignments();
              _loadContractsWithPdf();
            }
          },
          validator: (value) {
            if (value == null || value.isEmpty) {
              return 'Please select a facility';
            }
            return null;
          },
        );
      },
    );
  }

  Widget _buildTenantSelector() {
    if (_selectedFacilityId == null) {
      return Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: AppTheme.primaryBlue.withOpacity(0.1),
          border: Border.all(color: AppTheme.primaryBlue),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          children: [
            Icon(Icons.info, color: AppTheme.primaryBlue),
            const SizedBox(width: 8),
            const Expanded(
              child: Text('Please select a facility first'),
            ),
          ],
        ),
      );
    }

    final facilityId = _selectedFacilityId!;
    if (kDebugMode) {
      print('📋 [ContractCreation] Loading tenants for facility: $facilityId');
    }
    return FutureBuilder<List<TenantModel>>(
      future: TenantService.getTenantsForFacility(facilityId),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(
            child: SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          );
        }

        if (snapshot.hasError) {
          if (kDebugMode) {
            print('❌ [ContractCreation] Tenant load error for $facilityId: ${snapshot.error}');
          }
          return Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: AppTheme.error.withOpacity(0.1),
              border: Border.all(color: AppTheme.error),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              children: [
                Icon(Icons.error, color: AppTheme.error),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Error loading tenants: ${snapshot.error}',
                    style: TextStyle(color: AppTheme.error),
                  ),
                ),
              ],
            ),
          );
        }

        final allTenants = snapshot.data ?? [];
        final tenants = allTenants.where((t) => t.isActive).toList();
        if (kDebugMode) {
          print('📋 [ContractCreation] Facility $facilityId: ${allTenants.length} total, ${tenants.length} active tenants');
        }

        if (tenants.isEmpty) {
          return Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: AppTheme.warning.withOpacity(0.1),
              border: Border.all(color: AppTheme.warning),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              children: [
                Icon(Icons.person, color: AppTheme.warning),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    allTenants.isEmpty
                        ? 'No tenants found for this facility. Add tenants under Tenants first.'
                        : 'No active tenants for this facility. ${allTenants.length} tenant(s) are inactive.',
                  ),
                ),
              ],
            ),
          );
        }
        
        return DropdownButtonFormField<String>(
          value: _selectedTenantId,
          decoration: const InputDecoration(
            labelText: 'Tenant',
            border: OutlineInputBorder(),
            prefixIcon: Icon(Icons.person),
          ),
          items: tenants.map<DropdownMenuItem<String>>((tenant) {
            return DropdownMenuItem<String>(
              value: tenant.id,
              child: Text(tenant.name),
            );
          }).toList(),
          onChanged: (value) {
            if (!mounted) return;
            if (value == null) {
              setState(() {
                _selectedTenantId = null;
                _selectedTenantModel = null;
              });
              _syncSignerAssignments();
              return;
            }

            final tenant = tenants.firstWhere(
              (t) => t.id == value,
              orElse: () => tenants.first,
            );

            setState(() {
              _selectedTenantId = value;
              _selectedTenantModel = tenant;
            });
            _syncSignerAssignments();
          },
          validator: (value) {
            if (value == null || value.isEmpty) {
              return 'Please select a tenant';
            }
            return null;
          },
        );
      },
    );
  }

  Widget _buildTemplateSelector() {
    if (_selectedFacilityId == null) {
      return const Text('Please select a facility first to view templates.');
    }

    final facilityId = _selectedFacilityId!;
    return ref.watch(contractTemplatesProvider(facilityId)).when(
      data: (templates) {
        final initial = _findTemplateById(templates, _selectedTemplateId);
        if (_selectedTemplateId != null && initial != null && _activeTemplate?.id != initial.id) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted) return;
            setState(() {
              _activeTemplate = initial;
            });
            _syncSignerAssignments();
          });
        }

        if (templates.isEmpty) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('No templates available. You can create a contract without a template.'),
              const SizedBox(height: 8),
              TextButton.icon(
                onPressed: () => _openManageTemplatesForFacility(),
                icon: const Icon(Icons.settings, size: 18),
                label: const Text('Manage templates for this facility'),
              ),
            ],
          );
        }

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            DropdownButtonFormField<String?>(
              value: _selectedTemplateId,
              decoration: const InputDecoration(
                labelText: 'Template (Optional)',
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.description),
              ),
              items: [
                const DropdownMenuItem<String?>(
                  value: null,
                  child: Text('No Template'),
                ),
                ...templates.map<DropdownMenuItem<String?>>((template) {
                  return DropdownMenuItem<String?>(
                    value: template.id,
                    child: Text(template.name),
                  );
                }),
              ],
              onChanged: (value) => _handleTemplateSelection(value, templates),
            ),
            const SizedBox(height: 6),
            Text(
              'Templates are per facility. Not seeing yours?',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
            TextButton.icon(
              onPressed: () => _openManageTemplatesForFacility(),
              icon: const Icon(Icons.settings, size: 18),
              label: const Text('Manage templates for this facility'),
            ),
          ],
        );
      },
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (error, stackTrace) => const Text('Error loading templates'),
    );
  }

  void _openManageTemplatesForFacility() {
    if (_selectedFacilityId == null) return;
    context.push('${AppRoute.contractTemplates}?facilityId=$_selectedFacilityId').then((_) {
      if (!mounted) return;
      ref.invalidate(contractTemplatesProvider(_selectedFacilityId!));
    });
  }

  Widget _buildFileUploadSection() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.upload_file, color: AppTheme.primaryBlueDark),
                const SizedBox(width: 8),
                Text(
                  'Upload PDF Contract',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            if (_selectedFile == null && _uploadedFileUrl == null) ...[
              OutlinedButton.icon(
                onPressed: _isUploading ? null : _pickFile,
                icon: const Icon(Icons.attach_file),
                label: const Text('Choose PDF File'),
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                ),
              ),
              if (_selectedFacilityId != null &&
                  _contractsWithPdf.where((c) => widget.contract?.id != c.id).isNotEmpty) ...[
                const SizedBox(height: 12),
                Text(
                  'Or use PDF from existing contract:',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: AppTheme.textSecondary,
                  ),
                ),
                const SizedBox(height: 8),
                _loadingContractsWithPdf
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : DropdownButtonFormField<ContractModel>(
                        value: null,
                        decoration: const InputDecoration(
                          border: OutlineInputBorder(),
                          prefixIcon: Icon(Icons.copy, size: 20),
                          contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                        ),
                        hint: const Text('Select contract to reuse PDF'),
                        isExpanded: true,
                        items: _contractsWithPdf
                            .where((c) => widget.contract?.id != c.id)
                            .map((c) {
                          return DropdownMenuItem<ContractModel>(
                            value: c,
                            child: Text(
                              c.title,
                              overflow: TextOverflow.ellipsis,
                              maxLines: 1,
                            ),
                          );
                        }).toList(),
                        onChanged: (contract) {
                          if (contract != null && mounted) {
                            setState(() {
                              _uploadedFileUrl = contract.fileUrl;
                              _uploadedFileName = '${contract.title} (from existing)';
                              // Optionally copy signature placeholders from source
                              final placeholders = contract.customFields?['signaturePlaceholders'];
                              if (placeholders is List && placeholders.isNotEmpty) {
                                _customSignaturePlaceholders = placeholders
                                    .map((e) => SignaturePlaceholder.fromMap(Map<String, dynamic>.from(e as Map)))
                                    .toList();
                              }
                            });
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Text('Using PDF from "${contract.title}"'),
                                backgroundColor: AppTheme.success,
                                duration: const Duration(seconds: 2),
                              ),
                            );
                          }
                        },
                      ),
              ],
              const SizedBox(height: 8),
              Text(
                'Upload a PDF contract document (optional). You can also use a template above.',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: AppTheme.textSecondary,
                ),
              ),
            ] else if (_isUploading) ...[
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      SizedBox(
                        width: 20,
                        height: 20,
                        child: _uploadProgress != null && _uploadProgress! < 1.0
                            ? CircularProgressIndicator(
                                value: _uploadProgress,
                                strokeWidth: 2,
                                valueColor: AlwaysStoppedAnimation<Color>(AppTheme.primaryBlue),
                              )
                            : CircularProgressIndicator(
                                strokeWidth: 2,
                                valueColor: AlwaysStoppedAnimation<Color>(AppTheme.primaryBlue),
                              ),
                      ),
                      const SizedBox(width: 12),
                      Text(
                        _uploadProgress != null && _uploadProgress! < 1.0
                            ? 'Uploading... ${(_uploadProgress! * 100).round()}%'
                            : 'Uploading file...',
                      ),
                    ],
                  ),
                  if (_uploadProgress != null && _uploadProgress! > 0 && _uploadProgress! < 1.0) ...[
                    const SizedBox(height: 8),
                    LinearProgressIndicator(
                      value: _uploadProgress,
                      backgroundColor: AppTheme.backgroundSecondary,
                      valueColor: AlwaysStoppedAnimation<Color>(AppTheme.primaryBlue),
                    ),
                  ],
                ],
              ),
            ] else if (_uploadedFileUrl != null) ...[
              // Uploaded file: filename, View, Replace, Remove
              Row(
                children: [
                  Icon(Icons.check_circle, color: AppTheme.success, size: 20),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _uploadedFileName ?? 'File uploaded',
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: AppTheme.success,
                        fontWeight: FontWeight.w500,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (_uploadedFileUrl != null)
                    IconButton(
                      icon: const Icon(Icons.open_in_new, size: 20),
                      onPressed: () => _openPdfUrl(_uploadedFileUrl!),
                      tooltip: 'View PDF',
                    ),
                  IconButton(
                    icon: const Icon(Icons.refresh, size: 20),
                    onPressed: _isUploading ? null : _pickFile,
                    tooltip: 'Replace PDF',
                  ),
                  IconButton(
                    icon: const Icon(Icons.close, size: 20),
                    onPressed: () {
                      setState(() {
                        _selectedFile = null;
                        _uploadedFileUrl = null;
                        _uploadedFileName = null;
                        _customSignaturePlaceholders = null;
                        _selectedTemplateId = null;
                        _activeTemplate = null;
                      });
                    },
                    tooltip: 'Remove file',
                  ),
                ],
              ),
            ] else if (_selectedFile != null) ...[
              // Show selected file (not yet uploaded)
              Row(
                children: [
                  Icon(Icons.description, color: AppTheme.primaryBlue, size: 20),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _selectedFile!.name,
                      style: Theme.of(context).textTheme.bodyMedium,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close, size: 20),
                    onPressed: () {
                      setState(() {
                        _selectedFile = null;
                        _uploadedFileUrl = null;
                        _customSignaturePlaceholders = null;
                        _selectedTemplateId = null;
                        _activeTemplate = null;
                      });
                    },
                    tooltip: 'Remove file',
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  Future<void> _pickFile() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['pdf'],
        withData: true,
      );

      if (result != null && result.files.isNotEmpty) {
        final file = result.files.single;
        
        // Validate file was selected
        if (file.name.isEmpty) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('Please select a valid PDF file'),
                backgroundColor: AppTheme.error,
              ),
            );
          }
          return;
        }
        
        // Check file size (max 10MB)
        if (file.size != null && file.size! > 10 * 1024 * 1024) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('File size must be less than 10MB'),
                backgroundColor: AppTheme.error,
              ),
            );
          }
          return;
        }
        
        // Verify file has data
        if (file.bytes == null || file.bytes!.isEmpty) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('File appears to be empty. Please select a different file.'),
                backgroundColor: AppTheme.error,
              ),
            );
          }
          return;
        }

        setState(() {
          _selectedFile = file;
          _uploadedFileUrl = null;
          _uploadedFileName = null;
          _selectedTemplateId = null;
          _activeTemplate = null;
        });
        
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('PDF file selected: ${file.name}'),
              backgroundColor: AppTheme.success,
              duration: const Duration(seconds: 2),
            ),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error picking file: $e'),
            backgroundColor: AppTheme.error,
          ),
        );
      }
    }
  }

  Future<void> _openPdfUrl(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null || !await canLaunchUrl(uri)) return;
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  Widget _buildExpirationDateSelector() {
    return InkWell(
      onTap: _selectExpirationDate,
      child: InputDecorator(
        decoration: const InputDecoration(
          labelText: 'Expiration Date (Optional)',
          border: OutlineInputBorder(),
          prefixIcon: Icon(Icons.calendar_today),
        ),
        child: Text(
          _expiresAt != null
              ? '${_expiresAt!.month}/${_expiresAt!.day}/${_expiresAt!.year}'
              : 'Select expiration date',
          style: _expiresAt != null
              ? null
              : TextStyle(color: AppTheme.textSecondary),
        ),
      ),
    );
  }

  Future<void> _selectExpirationDate() async {
    final date = await showDatePicker(
      context: context,
      initialDate: _expiresAt ?? DateTime.now().add(const Duration(days: 365)),
      firstDate: DateTime.now(),
      lastDate: DateTime.now().add(const Duration(days: 3650)), // 10 years
    );

    if (date != null && mounted) {
      setState(() {
        _expiresAt = date;
      });
    }
  }

  Future<void> _createContract() async {
    if (!_formKey.currentState!.validate()) {
      return;
    }

    if (_selectedFacilityId == null || _selectedTenantId == null) {
      setState(() {
        _errorMessage = 'Please select both facility and tenant';
      });
      return;
    }

    // Prevent multiple submissions
    if (_isLoading) return;

    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    // When both template and file are selected, use the uploaded file as the document.
    // Template provides signers/metadata; file provides the PDF.
    
    // Validate terms acceptance
    if (!_hasAcceptedTerms) {
      setState(() {
        _errorMessage = 'You must accept the Terms of Service to use contract features.';
        _isLoading = false;
      });
      await _showTermsAcceptanceModal();
      return;
    }
    
    // Validate rights attestation if file is being uploaded
    if ((_selectedFile != null || _uploadedFileUrl != null) && !_rightsAttestationChecked) {
      setState(() {
        _errorMessage = 'You must confirm your legal rights to upload and use this document.';
        _isLoading = false;
      });
      return;
    }

    // If in edit mode, update existing contract
    if (widget.isEditMode && widget.contract != null) {
      await _updateContract();
      return;
    }

    Map<String, dynamic>? customFields;
    String? fileUrl = _uploadedFileUrl;

    // Build customFields when we have PDF and configured placeholders or template
    if (_activeTemplate != null) {
      customFields = _buildCustomFieldsForTemplate(_activeTemplate!);
    } else if (_customSignaturePlaceholders != null && _customSignaturePlaceholders!.isNotEmpty) {
      customFields = {
        'signers': [
          {'signerId': 'tenantPrimary', 'label': 'Tenant', 'role': 'tenant', 'name': _selectedTenantModel?.name ?? '', 'email': _selectedTenantModel?.email},
        ],
        'signaturePlaceholders': _customSignaturePlaceholders!.map((f) => f.toMap()).toList(),
      };
    }
    
    // If file is selected, upload it first
    if (_selectedFile != null && _selectedFile!.bytes != null) {
      setState(() {
        _isUploading = true;
        _uploadProgress = 0.0;
      });
      final fileName = _selectedFile!.name;
      try {
        // Verify file bytes are available before proceeding
        if (_selectedFile!.bytes == null || _selectedFile!.bytes!.isEmpty) {
          throw Exception('File data is missing. Please select the file again.');
        }

        if (kDebugMode) {
          print('📄 Creating contract and uploading PDF: $fileName');
        }

        // Create contract first to get contract ID (call service directly to get ID)
        final contractId = await ContractService.createContract(
          facilityId: _selectedFacilityId!,
          tenantId: _selectedTenantId!,
          title: _titleController.text.trim(),
          description: _descriptionController.text.trim(),
          type: _selectedType,
          templateId: _selectedTemplateId,
          fileUrl: null, // Will update after upload
          expiresAt: _expiresAt,
          customFields: customFields,
          notes: _notesController.text.trim().isEmpty ? null : _notesController.text.trim(),
        );

        // Update contract with compliance fields
        await _firestore
            .collection('facilities')
            .doc(_selectedFacilityId!)
            .collection('contracts')
            .doc(contractId)
            .update({
          'isLicensedForm': _isLicensedForm,
          'complianceStatus': 'active',
        });

        if (kDebugMode) {
          print('✅ Contract created with ID: $contractId');
          print('📤 Uploading PDF file...');
        }

        // Upload file with progress (always clears spinner in finally)
        fileUrl = await ContractService.uploadContractFile(
          facilityId: _selectedFacilityId!,
          contractId: contractId,
          fileData: Uint8List.fromList(_selectedFile!.bytes!),
          fileName: fileName,
          onProgress: (bytes, total) {
            if (!mounted) return;
            setState(() {
              _uploadProgress = total > 0 ? bytes / total : 0.0;
            });
          },
        );

        if (kDebugMode) {
          print('✅ PDF uploaded successfully: $fileUrl');
        }

        // Record rights attestation (use exact text from ComplianceService)
        final attestationText = ComplianceService.rightsAttestationText;
        final contractDoc = await _firestore
            .collection('facilities')
            .doc(_selectedFacilityId!)
            .collection('contracts')
            .doc(contractId)
            .get();
        final documentSha256 = contractDoc.data()?['documentSha256'] as String?;

        await ComplianceService.recordRightsAttestation(
          facilityId: _selectedFacilityId!,
          documentId: contractId,
          attestationText: attestationText,
          documentSha256: documentSha256,
          userAgent: _getUserAgent(),
        );

        await AuditService.logContractUploaded(
          facilityId: _selectedFacilityId!,
          contractId: contractId,
          fileName: fileName,
          isLicensedForm: _isLicensedForm,
          documentSha256: documentSha256,
        );

        await AuditService.logRightsAttested(
          facilityId: _selectedFacilityId!,
          documentId: contractId,
          documentType: 'contract',
          documentSha256: documentSha256,
        );

        // Update state so UI shows success immediately (no spinner)
        if (mounted) {
          setState(() {
            _isUploading = false;
            _uploadProgress = null;
            _isLoading = false;
            _uploadedFileUrl = fileUrl;
            _uploadedFileName = fileName;
            _selectedFile = null;
          });
          await Future.microtask(() {});
          if (!mounted) return;
          _showPostCreateActionsDialog(contractId);
        }
        return;
      } catch (e) {
        if (mounted) {
          setState(() {
            _errorMessage = 'Error uploading file: $e';
            _isLoading = false;
          });
        }
        return;
      } finally {
        // Always clear uploading state so spinner never sticks
        if (mounted) {
          setState(() {
            _isUploading = false;
            _uploadProgress = null;
          });
        }
      }
    }

    // Template selected but no file: generate PDF from template content
    if (_selectedTemplateId != null &&
        _selectedFile == null &&
        _uploadedFileUrl == null) {
      try {
        final template = await ContractService.getContractTemplate(
          facilityId: _selectedFacilityId!,
          templateId: _selectedTemplateId!,
        );
        if (template == null) {
          if (mounted) {
            setState(() {
              _errorMessage = 'Template not found. Please select a different template or upload a PDF.';
              _isLoading = false;
            });
          }
          return;
        }
        if (template.content.isNotEmpty) {
          if (_activeTemplate != null) {
            final validationMessage = _validateSignerAssignments(_activeTemplate!);
            if (validationMessage != null) {
              setState(() {
                _errorMessage = validationMessage;
                _isLoading = false;
              });
              return;
            }
            customFields ??= _buildCustomFieldsForTemplate(_activeTemplate!);
          }

          // DNR check before creating
          if (!_dnrOverride && _selectedTenantModel != null) {
            try {
              final dnrMatches = await DNRService.findDNRMatches(
                facilityId: _selectedFacilityId!,
                name: _selectedTenantModel!.name,
                email: _selectedTenantModel!.email,
                phone: _selectedTenantModel!.phone,
              );
              if (dnrMatches.isNotEmpty) {
                setState(() {
                  _dnrMatches = dnrMatches;
                  _isLoading = false;
                });
                final shouldProceed = await _showDNRBlockingDialog(context, dnrMatches);
                if (!shouldProceed) return;
                _dnrOverride = true;
                setState(() => _isLoading = true);
              }
            } catch (e) {
              if (kDebugMode) print('⚠️ Error checking DNR: $e');
            }
          }

          setState(() {
            _isUploading = true;
            _uploadProgress = 0.0;
          });

          final contractTitle = _titleController.text.trim();
          final pdfBytes = await ContractService.generatePdfFromTemplateContent(
            content: template.content,
            title: contractTitle,
          );

          final contractId = await ContractService.createContract(
            facilityId: _selectedFacilityId!,
            tenantId: _selectedTenantId!,
            title: contractTitle,
            description: _descriptionController.text.trim(),
            type: _selectedType,
            templateId: _selectedTemplateId,
            fileUrl: null,
            expiresAt: _expiresAt,
            customFields: customFields,
            notes: _notesController.text.trim().isEmpty ? null : _notesController.text.trim(),
          );

          await _firestore
              .collection('facilities')
              .doc(_selectedFacilityId!)
              .collection('contracts')
              .doc(contractId)
              .update({
            'isLicensedForm': _isLicensedForm,
            'complianceStatus': 'active',
          });

          final fileName = '${template.name.replaceAll(RegExp(r'[^\w\s-]'), '').trim().replaceAll(RegExp(r'\s+'), '_')}.pdf';
          fileUrl = await ContractService.uploadContractFile(
            facilityId: _selectedFacilityId!,
            contractId: contractId,
            fileData: pdfBytes,
            fileName: fileName,
            onProgress: (bytes, total) {
              if (!mounted) return;
              setState(() {
                _uploadProgress = total > 0 ? bytes / total : 1.0;
              });
            },
          );

          final contractDoc = await _firestore
              .collection('facilities')
              .doc(_selectedFacilityId!)
              .collection('contracts')
              .doc(contractId)
              .get();
          final documentSha256 = contractDoc.data()?['documentSha256'] as String?;

          await ComplianceService.recordRightsAttestation(
            facilityId: _selectedFacilityId!,
            documentId: contractId,
            attestationText: ComplianceService.rightsAttestationText,
            documentSha256: documentSha256,
            userAgent: _getUserAgent(),
          );

          await AuditService.logContractUploaded(
            facilityId: _selectedFacilityId!,
            contractId: contractId,
            fileName: fileName,
            isLicensedForm: _isLicensedForm,
            documentSha256: documentSha256,
          );

          await AuditService.logRightsAttested(
            facilityId: _selectedFacilityId!,
            documentId: contractId,
            documentType: 'contract',
            documentSha256: documentSha256,
          );

          if (_dnrOverride && _dnrMatches != null && _dnrMatches!.isNotEmpty && _selectedTenantModel != null) {
            try {
              await AuditService.logDNRAction(
                facilityId: _selectedFacilityId!,
                action: 'dnr.override.contract',
                targetId: _selectedTenantId!,
                details: {
                  'tenantName': _selectedTenantModel!.name,
                  'tenantEmail': _selectedTenantModel!.email,
                  'contractTitle': contractTitle,
                  'matchedDnrIds': _dnrMatches!.map((m) => m.id).toList(),
                  'matchedDnrNames': _dnrMatches!.map((m) => m.name).toList(),
                },
              );
            } catch (e) {
              if (kDebugMode) print('⚠️ Error logging DNR override: $e');
            }
          }

          if (mounted) {
            setState(() {
              _isUploading = false;
              _uploadProgress = null;
              _isLoading = false;
            });
            _showPostCreateActionsDialog(contractId);
          }
          return;
        }
        // Template has no content
        if (mounted) {
          setState(() {
            _errorMessage = 'This template has no content. Please edit the template to add terms, or upload a PDF file instead.';
            _isLoading = false;
          });
        }
        return;
      } catch (e) {
        if (mounted) {
          setState(() {
            _errorMessage = 'Failed to generate document from template: $e';
            _isLoading = false;
          });
        }
        return;
      } finally {
        if (mounted) {
          setState(() {
            _isUploading = false;
            _uploadProgress = null;
          });
        }
      }
    }

    if (_activeTemplate != null) {
      final validationMessage = _validateSignerAssignments(_activeTemplate!);
      if (validationMessage != null) {
        setState(() {
          _errorMessage = validationMessage;
          _isLoading = false;
        });
        return;
      }
      customFields = _buildCustomFieldsForTemplate(_activeTemplate!);
    }

    // Check for global DNR matches before creating contract
    if (!_dnrOverride && _selectedTenantModel != null) {
      try {
        final dnrMatches = await DNRService.findDNRMatches(
          facilityId: _selectedFacilityId!,
          name: _selectedTenantModel!.name,
          email: _selectedTenantModel!.email,
          phone: _selectedTenantModel!.phone,
        );

        if (dnrMatches.isNotEmpty) {
          setState(() {
            _dnrMatches = dnrMatches;
            _isLoading = false;
          });

          // Show blocking dialog
          final shouldProceed = await _showDNRBlockingDialog(context, dnrMatches);
          if (!shouldProceed) {
            return; // User cancelled
          }
          // User chose to override - set flag and continue
          _dnrOverride = true;
          setState(() {
            _isLoading = true;
          });
        }
      } catch (e) {
        if (kDebugMode) {
          print('⚠️ Error checking DNR: $e');
        }
        // Continue with contract creation if DNR check fails (non-blocking)
      }
    }

    try {
      final user = ref.read(authStateProvider).value;
      if (user == null) {
        throw Exception('User not authenticated');
      }

      final contractId = await ref.read(contractOperationsProvider.notifier).createContract(
        facilityId: _selectedFacilityId!,
        tenantId: _selectedTenantId!,
        title: _titleController.text.trim(),
        description: _descriptionController.text.trim(),
        type: _selectedType,
        templateId: _selectedTemplateId,
        fileUrl: fileUrl,
        expiresAt: _expiresAt,
        customFields: customFields,
        notes: _notesController.text.trim().isEmpty ? null : _notesController.text.trim(),
      );

      // Log DNR override if it was used
      if (_dnrOverride && _dnrMatches != null && _dnrMatches!.isNotEmpty && _selectedTenantModel != null) {
        try {
          await AuditService.logDNRAction(
            facilityId: _selectedFacilityId!,
            action: 'dnr.override.contract',
            targetId: _selectedTenantId!,
            details: {
              'tenantName': _selectedTenantModel!.name,
              'tenantEmail': _selectedTenantModel!.email,
              'contractTitle': _titleController.text.trim(),
              'matchedDnrIds': _dnrMatches!.map((m) => m.id).toList(),
              'matchedDnrNames': _dnrMatches!.map((m) => m.name).toList(),
            },
          );
        } catch (e) {
          if (kDebugMode) {
            print('⚠️ Error logging DNR override: $e');
          }
        }
      }

      if (mounted) {
        await _showPostCreateActionsDialog(contractId);
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _errorMessage = 'Failed to create contract: ${e.toString()}';
          _isLoading = false;
        });
      }
    }
  }

  Future<void> _updateContract() async {
    if (widget.contract == null) return;

    try {
      String? fileUrl = _uploadedFileUrl;
      
      // If new file is selected, upload it
      if (_selectedFile != null && _selectedFile!.bytes != null) {
        setState(() {
          _isUploading = true;
          _uploadProgress = 0.0;
        });
        try {
          fileUrl = await ContractService.uploadContractFile(
            facilityId: _selectedFacilityId!,
            contractId: widget.contract!.id,
            fileData: Uint8List.fromList(_selectedFile!.bytes!),
            fileName: _selectedFile!.name,
            onProgress: (bytes, total) {
              if (!mounted) return;
              setState(() {
                _uploadProgress = total > 0 ? bytes / total : 0.0;
              });
            },
          );
          if (mounted) {
            setState(() {
              _isUploading = false;
              _uploadProgress = null;
              _uploadedFileUrl = fileUrl;
              _uploadedFileName = _selectedFile!.name;
              _selectedFile = null;
            });
          }
        } catch (e) {
          if (mounted) {
            setState(() {
              _errorMessage = 'Error uploading file: $e';
              _isLoading = false;
            });
          }
          return;
        } finally {
          if (mounted) {
            setState(() {
              _isUploading = false;
              _uploadProgress = null;
            });
          }
        }
      }

      // Update contract
      await ContractService.updateContract(
        facilityId: _selectedFacilityId!,
        contractId: widget.contract!.id,
        title: _titleController.text.trim(),
        description: _descriptionController.text.trim().isEmpty ? null : _descriptionController.text.trim(),
        type: _selectedType,
        fileUrl: fileUrl,
        expiresAt: _expiresAt,
        notes: _notesController.text.trim().isEmpty ? null : _notesController.text.trim(),
      );

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Contract "${_titleController.text.trim()}" updated successfully!'),
            backgroundColor: AppTheme.success,
          ),
        );
        context.pop(true); // Return success
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _errorMessage = 'Failed to update contract: ${e.toString()}';
          _isLoading = false;
        });
      }
    }
  }

  /// Show DNR blocking dialog and return whether user wants to proceed
  Future<bool> _showDNRBlockingDialog(BuildContext context, List<DNRModel> matches) async {
    return await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext context) {
        return AlertDialog(
          title: Row(
            children: [
              Icon(Icons.warning, color: AppTheme.error),
              const SizedBox(width: 8),
              const Text('DNR Alert - Global Match Found'),
            ],
          ),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  "This tenant matches ${matches.length} active DNR entr${matches.length == 1 ? 'y' : 'ies'} (your organization's facility list and/or the SFC platform-wide list):",
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 16),
                ...matches.map((match) => Card(
                  color: AppTheme.error.withOpacity(0.1),
                  margin: const EdgeInsets.only(bottom: 8),
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Name: ${match.name}',
                          style: const TextStyle(fontWeight: FontWeight.bold),
                        ),
                        if (match.email.isNotEmpty)
                          Text('Email: ${match.email}'),
                        if (match.phone.isNotEmpty)
                          Text('Phone: ${match.phone}'),
                        Text('Reason: ${match.reason}'),
                        if (match.facilityName != null)
                          Text(
                            'From Facility: ${match.facilityName}',
                            style: TextStyle(fontSize: 12, color: AppTheme.textSecondary, fontWeight: FontWeight.w500),
                          ),
                        if (match.addedByName != null && match.addedByEmail != null)
                          Text(
                            'Added by: ${match.addedByName} (${match.addedByEmail})',
                            style: TextStyle(fontSize: 12, color: AppTheme.textSecondary),
                          ),
                        if (match.expiresAt != null)
                          Text(
                            'Expires: ${match.expiresAt!.toLocal().toString().split(' ')[0]}',
                            style: TextStyle(fontSize: 12, color: AppTheme.textSecondary),
                          ),
                      ],
                    ),
                  ),
                )),
                const SizedBox(height: 16),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: AppTheme.warning.withOpacity(0.1),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: AppTheme.warning),
                  ),
                  child: const Text(
                    '⚠️ Proceeding will create this contract despite DNR matches. This action will be logged for audit purposes.',
                    style: TextStyle(fontSize: 12),
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () {
                Navigator.of(context).pop(false); // Cancel
              },
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: () {
                Navigator.of(context).pop(true); // Proceed with override
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: AppTheme.error,
                foregroundColor: AppTheme.textOnDark,
              ),
              child: const Text('Override & Continue'),
            ),
          ],
        );
      },
    ) ?? false; // Default to false if dialog is dismissed
  }

  Widget _buildComplianceSection() {
    return Card(
      color: AppTheme.backgroundLight,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.verified_user, color: AppTheme.primaryBlueDark),
                const SizedBox(width: 8),
                Text(
                  'Compliance & Rights',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            
            // Rights Attestation (Required)
            CheckboxListTile(
              value: _rightsAttestationChecked,
              onChanged: (value) {
                setState(() {
                  _rightsAttestationChecked = value ?? false;
                });
              },
              title: const Text(
                'I confirm I have the legal right to upload and use this document and to request signatures for it (including any association or licensed forms).',
                style: TextStyle(fontSize: 14),
              ),
              controlAffinity: ListTileControlAffinity.leading,
              contentPadding: EdgeInsets.zero,
            ),
            Padding(
              padding: const EdgeInsets.only(left: 40, top: 4),
              child: Text(
                'You are responsible for ensuring you have any required rights, licenses, or memberships to use this document.',
                style: TextStyle(
                  fontSize: 12,
                  color: AppTheme.textSecondary,
                ),
              ),
            ),
            
            const SizedBox(height: 12),
            
            // Licensed Form Checkbox (Optional)
            CheckboxListTile(
              value: _isLicensedForm,
              onChanged: (value) {
                setState(() {
                  _isLicensedForm = value ?? false;
                });
              },
              title: const Text(
                'This is an association/licensed form (e.g., TSSA).',
                style: TextStyle(fontSize: 14),
              ),
              controlAffinity: ListTileControlAffinity.leading,
              contentPadding: EdgeInsets.zero,
            ),
            
            // Show note if licensed form is checked
            if (_isLicensedForm) ...[
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: AppTheme.warning.withOpacity(0.1),
                  border: Border.all(color: AppTheme.warning),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.info_outline, color: AppTheme.warning, size: 20),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'You are responsible for maintaining any required membership/license to use this form. SFC does not verify membership status.',
                        style: TextStyle(
                          fontSize: 12,
                          color: AppTheme.textSecondary,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
            
            const SizedBox(height: 12),
            
          ],
        ),
      ),
    );
  }
  
  Future<void> _showTermsAcceptanceModal() async {
    if (!mounted) return;
    
    final accepted = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Text('Contract Upload & e-Signing Terms'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Storage Facility Creator ("SFC") provides tools to upload documents and request electronic signatures. SFC does not provide legal advice and does not create, own, or license the documents you upload.',
                ),
                const SizedBox(height: 16),
                const Text(
                  'By enabling contract upload and e-signing for your facility, you agree that:',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 12),
                const Text('1) Your documents; your responsibility. You are solely responsible for the documents you upload, send, and use (including any association or licensed forms).'),
                const SizedBox(height: 12),
                const Text('2) Rights and permissions. You represent and warrant that you have all necessary rights, permissions, licenses, and consents to upload, store, send, and request signatures on the documents you use in SFC.'),
                const SizedBox(height: 12),
                const Text('3) No distribution by SFC. You understand SFC does not provide association forms or distribute third-party contracts to other customers.'),
                const SizedBox(height: 12),
                const Text('4) Takedown / disabling. If SFC receives a complaint, legal notice, or otherwise believes a document may be unauthorized, SFC may disable the document/template and suspend its use for new signature requests.'),
                const SizedBox(height: 12),
                const Text('5) Indemnification. You agree to defend and indemnify SFC from claims, damages, liabilities, and expenses (including reasonable attorneys\' fees) arising out of your documents, your use of third-party or licensed forms, or your violation of any rights or laws.'),
                const SizedBox(height: 16),
                Text(
                  'We store an audit record of your acceptance (date/time, facility, and Terms version).',
                  style: TextStyle(
                    fontSize: 11,
                    color: AppTheme.textSecondary,
                    fontStyle: FontStyle.italic,
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Decline'),
            ),
            ElevatedButton(
              onPressed: () => Navigator.of(context).pop(true),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppTheme.primaryBlueDark,
                foregroundColor: AppTheme.textOnDark,
              ),
              child: const Text('I Agree & Enable'),
            ),
          ],
        );
      },
    );
    
    if (accepted == true && _selectedFacilityId != null) {
      try {
        await ComplianceService.acceptTerms(_selectedFacilityId!);
        if (mounted) {
          setState(() {
            _hasAcceptedTerms = true;
          });
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Error accepting terms: $e'),
              backgroundColor: AppTheme.error,
            ),
          );
        }
      }
    } else if (accepted == false) {
      // User cancelled - navigate back
      if (mounted) {
        Navigator.of(context).pop();
      }
    }
  }
  
  String? _getUserAgent() {
    // User agent capture would require JavaScript interop
    // For now, return null - it's optional and can be added later
    return null;
  }
  
  Future<void> _showPostCreateActionsDialog(String contractId) async {
    setState(() {
      _isLoading = false;
    });

    if (_selectedFacilityId == null) return;

    final contract = await ContractService.getContract(
      _selectedFacilityId!,
      contractId,
    );
    if (contract == null || !mounted) return;

    final action = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.check_circle, color: AppTheme.success, size: 28),
            SizedBox(width: 8),
            Text('Contract created'),
          ],
        ),
        content: Text(
          '"${contract.title}" is ready. What would you like to do next?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop('draft'),
            child: const Text('Save as draft'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop('in_person'),
            child: const Text('Sign in person'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(context).pop('send'),
            child: const Text('Send for signature'),
          ),
        ],
      ),
    );

    if (!mounted) return;

    final sentBy = ref.read(authStateProvider).value?.uid ?? '';
    if (action == 'send') {
      await ContractSendService.sendContractForSignature(
        context: context,
        contract: contract,
        sentBy: sentBy,
      );
    } else if (action == 'in_person') {
      await ContractSendService.signContractInPerson(
        context: context,
        contract: contract,
        sentBy: sentBy,
      );
    }

    _navigateToContractsList();
  }

  void _navigateToContractsList() {
    if (widget.facilityId != null && widget.facilityId!.isNotEmpty) {
      ref.invalidate(contractsProvider(widget.facilityId!));
    }
    final uri = widget.facilityId != null && widget.facilityId!.isNotEmpty
        ? '${AppRoute.contracts}?facilityId=${widget.facilityId}'
        : AppRoute.contracts;
    context.go(uri);
  }
}
