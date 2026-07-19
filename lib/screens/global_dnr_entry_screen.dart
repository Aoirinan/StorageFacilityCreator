import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:file_picker/file_picker.dart';
import 'package:go_router/go_router.dart';
import '../models/global_dnr_model.dart';
import '../models/permission_model.dart';
import '../models/tenant_model.dart';
import '../providers/auth_provider.dart';
import '../providers/facility_provider.dart';
import '../providers/tenant_provider.dart';
import '../models/facility_model.dart';
import '../router/app_route.dart';
import '../services/dnr_terms_service.dart';
import '../services/global_dnr_service.dart';
import '../services/facility_service.dart';
import '../services/permission_service.dart';
import '../theme/app_theme.dart';
import '../widgets/modern_page_wrapper.dart';
import 'global_dnr_detail_screen.dart';

/// Evidence file picked in the form, held in memory until the entry is created.
class _PendingEvidence {
  final String filename;
  final Uint8List bytes;
  final bool isPhoto;

  const _PendingEvidence({
    required this.filename,
    required this.bytes,
    required this.isPhoto,
  });
}

/// A facility staff member selectable as the reporter ("Reported by") of an entry.
class _StaffOption {
  final String userId;
  final String displayName;
  final String email;
  final String? phone;
  final String roleLabel;

  const _StaffOption({
    required this.userId,
    required this.displayName,
    required this.email,
    this.phone,
    required this.roleLabel,
  });
}

/// Form to add a new entry to the Global DNR collection (shared platform-wide across all SFC operators).
class GlobalDNREntryScreen extends ConsumerStatefulWidget {
  const GlobalDNREntryScreen({super.key});

  @override
  ConsumerState<GlobalDNREntryScreen> createState() => _GlobalDNREntryScreenState();
}

class _GlobalDNREntryScreenState extends ConsumerState<GlobalDNREntryScreen> {
  final _formKey = GlobalKey<FormState>();
  final _fullNameController = TextEditingController();
  final _dobController = TextEditingController();
  final _phoneController = TextEditingController();
  final _emailController = TextEditingController();
  final _reasonController = TextEditingController();
  final _notesController = TextEditingController();
  final _idLast4Controller = TextEditingController();

  GlobalDnrSeverity _severity = GlobalDnrSeverity.medium;
  String? _selectedFacilityId;
  bool _accuracyAttested = false;
  bool _isLoading = false;
  String? _errorMessage;

  List<_StaffOption> _staffOptions = [];
  bool _staffLoading = false;
  String? _selectedStaffUserId;
  String? _selectedTenantId;
  final List<_PendingEvidence> _pendingEvidence = [];
  String? _uploadStatus;

  @override
  void initState() {
    super.initState();
    _setDefaultFacility();
  }

  Future<void> _setDefaultFacility() async {
    final fid = await GlobalDNRService.getCurrentUserFirstFacilityId();
    if (mounted && fid != null) {
      setState(() => _selectedFacilityId = fid);
      _loadStaffOptions(fid);
    }
  }

  /// Load the facility's staff (owner/manager/employee) for the "Reported by" dropdown.
  Future<void> _loadStaffOptions(String facilityId) async {
    setState(() {
      _staffLoading = true;
      _staffOptions = [];
      _selectedStaffUserId = null;
      _selectedTenantId = null;
    });

    final options = <_StaffOption>[];
    final seenUserIds = <String>{};

    try {
      // Current user first — always available even if profile reads are restricted.
      final authUser = ref.read(authStateProvider).value;
      if (authUser != null) {
        final profile = await PermissionService.getUserProfile(authUser.uid);
        options.add(_StaffOption(
          userId: authUser.uid,
          displayName: (profile?['displayName'] as String?)?.trim().isNotEmpty == true
              ? (profile!['displayName'] as String).trim()
              : (authUser.email ?? 'Me').split('@').first,
          email: authUser.email ?? (profile?['email'] as String? ?? ''),
          phone: (profile?['phoneNumber'] ?? profile?['phone']) as String?,
          roleLabel: 'You',
        ));
        seenUserIds.add(authUser.uid);
      }

      // Other staff with roles at this facility.
      final userRoles = await PermissionService.getFacilityUsers(facilityId);
      for (final userRole in userRoles) {
        if (userRole.userId.isEmpty || seenUserIds.contains(userRole.userId)) {
          continue;
        }
        seenUserIds.add(userRole.userId);
        final profile = await PermissionService.getUserProfile(userRole.userId);
        final email = profile?['email'] as String? ?? '';
        final displayName =
            (profile?['displayName'] as String?)?.trim().isNotEmpty == true
                ? (profile!['displayName'] as String).trim()
                : (email.isNotEmpty ? email.split('@').first : 'Staff member');
        options.add(_StaffOption(
          userId: userRole.userId,
          displayName: displayName,
          email: email,
          phone: (profile?['phoneNumber'] ?? profile?['phone']) as String?,
          roleLabel: userRole.roleType.displayName,
        ));
      }
    } catch (_) {
      // Staff lookup is best-effort; manual entry always remains available.
    }

    if (mounted) {
      setState(() {
        _staffOptions = options;
        _staffLoading = false;
        // Default the reporter to the current user.
        final authUser = ref.read(authStateProvider).value;
        if (authUser != null &&
            options.any((option) => option.userId == authUser.uid)) {
          _selectedStaffUserId = authUser.uid;
        } else if (options.isNotEmpty) {
          _selectedStaffUserId = options.first.userId;
        }
      });
    }
  }

  _StaffOption? get _selectedStaffOption {
    for (final option in _staffOptions) {
      if (option.userId == _selectedStaffUserId) return option;
    }
    return null;
  }

  /// Tenant picked as the DNR subject — auto-fills their contact details.
  void _applyTenantSelection(String? tenantId, List<TenantModel> tenants) {
    setState(() => _selectedTenantId =
        (tenantId == null || tenantId.isEmpty) ? null : tenantId);
    if (tenantId == null || tenantId.isEmpty) return;
    TenantModel? match;
    for (final tenant in tenants) {
      if (tenant.id == tenantId) {
        match = tenant;
        break;
      }
    }
    if (match == null) return;
    _fullNameController.text = match.name;
    _emailController.text = match.email;
    _phoneController.text = match.phone;
  }

  @override
  void dispose() {
    _fullNameController.dispose();
    _dobController.dispose();
    _phoneController.dispose();
    _emailController.dispose();
    _reasonController.dispose();
    _notesController.dispose();
    _idLast4Controller.dispose();
    super.dispose();
  }

  Future<void> _pickEvidence() async {
    // Single picker (photos and documents alike); photo-ness is detected from
    // the file extension so images get thumbnails and correct content types.
    final result = await FilePicker.platform.pickFiles(
      type: FileType.any,
      allowMultiple: true,
      withData: true,
    );
    if (result == null || result.files.isEmpty) return;

    setState(() {
      for (final file in result.files) {
        final bytes = file.bytes;
        if (bytes == null || bytes.isEmpty) continue;
        _pendingEvidence.add(_PendingEvidence(
          filename: file.name,
          bytes: bytes,
          isPhoto: GlobalDNRService.isPhotoFilename(file.name),
        ));
      }
    });
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    final facilityId = _selectedFacilityId;
    if (facilityId == null || facilityId.isEmpty) {
      setState(() => _errorMessage = 'Please select a facility.');
      return;
    }
    if (!_accuracyAttested) {
      setState(() => _errorMessage =
          'Please confirm the accuracy attestation before adding this entry.');
      return;
    }

    // Creating shared entries requires recorded DNR terms acceptance (rules-enforced).
    final termsOk = await DnrTermsService.ensureAccepted(context);
    if (!termsOk) {
      setState(() =>
          _errorMessage = 'DNR terms must be accepted before creating entries.');
      return;
    }

    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final facilities = await FacilityService.getUserFacilities();
      FacilityModel? facility;
      for (final f in facilities) {
        if (f.id == facilityId) { facility = f; break; }
      }
      if (facility == null) throw Exception('Facility not found');

      final reporter = _selectedStaffOption;

      final entryId = await GlobalDNRService.createGlobalDNREntry(
        fullName: _fullNameController.text.trim(),
        dob: _dobController.text.trim().isEmpty ? null : _dobController.text.trim(),
        phone: _phoneController.text.trim(),
        email: _emailController.text.trim(),
        reason: _reasonController.text.trim(),
        notes: _notesController.text.trim().isEmpty ? null : _notesController.text.trim(),
        driversLicenseLast4: _idLast4Controller.text.trim().length >= 4 ? _idLast4Controller.text.trim() : null,
        severity: _severity,
        createdByFacilityId: facilityId,
        createdByFacilityName: facility.name,
        createdByState: null,
        accuracyAttested: _accuracyAttested,
        reportedByName: reporter?.displayName,
        reportedByEmail: reporter?.email,
        linkedTenantId: _selectedTenantId,
      );

      // Upload any evidence picked in the form (entry must exist first —
      // Storage rules authorize uploads against the created entry).
      var uploadFailures = 0;
      for (var i = 0; i < _pendingEvidence.length; i++) {
        final evidence = _pendingEvidence[i];
        if (mounted) {
          setState(() =>
              _uploadStatus = 'Uploading evidence ${i + 1} of ${_pendingEvidence.length}\u2026');
        }
        try {
          await GlobalDNRService.addEvidence(
            entryId: entryId,
            bytes: evidence.bytes,
            filename: evidence.filename,
            isPhoto: evidence.isPhoto,
          );
        } catch (e) {
          uploadFailures++;
          if (kDebugMode) {
            print('⚠️ Evidence upload failed for ${evidence.filename}: $e');
          }
        }
      }

      if (!mounted) return;

      if (uploadFailures > 0) {
        // Entry exists; let the user retry uploads from the detail screen.
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
                'Entry created, but $uploadFailures evidence file(s) failed to upload. Retry from this screen.'),
            backgroundColor: AppTheme.warning,
            duration: const Duration(seconds: 6),
          ),
        );
        final entry = await GlobalDNRService.getGlobalDNREntry(entryId);
        if (!mounted) return;
        if (entry != null) {
          context.pushReplacement(AppRoute.legacyScreen,
              extra: GlobalDNRDetailScreen(entry: entry));
        } else {
          Navigator.of(context).pop(true);
        }
        return;
      }

      Navigator.of(context).pop(true);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(_pendingEvidence.isEmpty
              ? 'Global DNR entry created'
              : 'Global DNR entry created with ${_pendingEvidence.length} evidence file(s)'),
          backgroundColor: AppTheme.success,
        ),
      );
    } catch (e) {
      if (mounted) {
        setState(() {
          _isLoading = false;
          _uploadStatus = null;
          _errorMessage = e.toString();
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final authState = ref.watch(authStateProvider);
    return authState.when(
      data: (user) {
        if (user == null) {
          return ModernPageWrapper(
            currentRoute: '/dnr',
            title: 'Add to Global DNR',
            child: const Center(child: Text('Please sign in to add a Global DNR entry.')),
          );
        }
        return ModernPageWrapper(
          currentRoute: '/dnr',
          title: 'Add to Global DNR',
          actions: [
            IconButton(
              icon: const Icon(Icons.close),
              tooltip: 'Back to DNR list',
              onPressed: () => Navigator.of(context).pop(),
            ),
          ],
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 760),
                child: Form(
              key: _formKey,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text(
                    'This entry is visible to every Storage Facility Creator subscriber, not only your sites. Only add individuals who should not be rented to anywhere on the platform.',
                    style: TextStyle(color: AppTheme.textSecondary, fontSize: 12),
                  ),
                  const SizedBox(height: 12),
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: AppTheme.warning.withOpacity(0.08),
                      border: Border.all(color: AppTheme.warning),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: const Text(
                      'Entries must be factual, based on your facility\'s direct business experience, and supported by '
                      'your internal records. Entries must not be based on race, color, religion, national origin, sex, '
                      'familial status, disability, age, or any other protected characteristic, and must comply with '
                      'applicable privacy, housing, consumer reporting, and defamation laws. This list is not a consumer '
                      'report and may not be used as one. Attach supporting evidence after saving. See the Do Not Rent '
                      'Data Policy for the dispute and correction process.',
                      style: TextStyle(fontSize: 12),
                    ),
                  ),
                  const SizedBox(height: 16),
                  if (_errorMessage != null) ...[
                    Container(
                      padding: const EdgeInsets.all(12),
                      margin: const EdgeInsets.only(bottom: 16),
                      decoration: BoxDecoration(
                        color: AppTheme.error.withOpacity(0.1),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: AppTheme.error),
                      ),
                      child: Text(_errorMessage!, style: const TextStyle(color: AppTheme.error)),
                    ),
                  ],
                  _buildFacilityDropdown(user.uid),
                  const SizedBox(height: 16),
                  _buildReportedByDropdown(),
                  const SizedBox(height: 12),
                  _buildTenantLinkDropdown(),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: _fullNameController,
                    decoration: const InputDecoration(
                      labelText: 'Full Name *',
                      border: OutlineInputBorder(),
                      prefixIcon: Icon(Icons.person),
                    ),
                    validator: (v) => (v == null || v.trim().isEmpty) ? 'Required' : null,
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: _dobController,
                    decoration: const InputDecoration(
                      labelText: 'DOB (optional)',
                      border: OutlineInputBorder(),
                      prefixIcon: Icon(Icons.calendar_today),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: _phoneController,
                    decoration: const InputDecoration(
                      labelText: 'Phone *',
                      border: OutlineInputBorder(),
                      prefixIcon: Icon(Icons.phone),
                    ),
                    keyboardType: TextInputType.phone,
                    validator: (v) => (v == null || v.trim().isEmpty) ? 'Required' : null,
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: _emailController,
                    decoration: const InputDecoration(
                      labelText: 'Email *',
                      border: OutlineInputBorder(),
                      prefixIcon: Icon(Icons.email),
                    ),
                    keyboardType: TextInputType.emailAddress,
                    validator: (v) => (v == null || v.trim().isEmpty) ? 'Required' : null,
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: _idLast4Controller,
                    decoration: const InputDecoration(
                      labelText: 'ID / License last 4 (optional)',
                      border: OutlineInputBorder(),
                      prefixIcon: Icon(Icons.badge),
                    ),
                    maxLength: 4,
                    keyboardType: TextInputType.number,
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: _reasonController,
                    decoration: const InputDecoration(
                      labelText: 'Reason for DNR *',
                      border: OutlineInputBorder(),
                      prefixIcon: Icon(Icons.warning),
                    ),
                    maxLines: 3,
                    validator: (v) => (v == null || v.trim().isEmpty) ? 'Required' : null,
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: _notesController,
                    decoration: const InputDecoration(
                      labelText: 'Notes (optional)',
                      border: OutlineInputBorder(),
                      prefixIcon: Icon(Icons.note),
                    ),
                    maxLines: 2,
                  ),
                  const SizedBox(height: 12),
                  _buildEvidenceSection(),
                  const SizedBox(height: 12),
                  DropdownButtonFormField<GlobalDnrSeverity>(
                    value: _severity,
                    decoration: const InputDecoration(
                      labelText: 'Severity',
                      border: OutlineInputBorder(),
                    ),
                    items: GlobalDnrSeverity.values
                        .map((s) => DropdownMenuItem(value: s, child: Text(s.value)))
                        .toList(),
                    onChanged: (v) => setState(() => _severity = v ?? GlobalDnrSeverity.medium),
                  ),
                  const SizedBox(height: 12),
                  CheckboxListTile(
                    value: _accuracyAttested,
                    onChanged: (v) => setState(() => _accuracyAttested = v ?? false),
                    controlAffinity: ListTileControlAffinity.leading,
                    title: const Text(
                      'I attest that this entry is factual, based on this facility\'s direct business experience, '
                      'supported by our internal records, and not based on any protected characteristic.',
                      style: TextStyle(fontSize: 13),
                    ),
                    contentPadding: EdgeInsets.zero,
                  ),
                  const SizedBox(height: 24),
                  ElevatedButton(
                    onPressed: _isLoading ? null : _submit,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppTheme.error,
                      foregroundColor: AppTheme.textOnDark,
                      padding: const EdgeInsets.symmetric(vertical: 16),
                    ),
                    child: _isLoading
                        ? Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              const SizedBox(
                                height: 20,
                                width: 20,
                                child: CircularProgressIndicator(
                                    strokeWidth: 2, color: AppTheme.textOnDark),
                              ),
                              const SizedBox(width: 12),
                              Text(_uploadStatus ?? 'Saving\u2026'),
                            ],
                          )
                        : const Text('Add to Global DNR'),
                  ),
                ],
              ),
                ),
              ),
            ),
          ),
        );
      },
      loading: () => const ModernPageWrapper(
        currentRoute: '/dnr',
        title: 'Add to Global DNR',
        child: Center(child: CircularProgressIndicator()),
      ),
      error: (e, _) => ModernPageWrapper(
        currentRoute: '/dnr',
        title: 'Add to Global DNR',
        child: Center(child: Text('Error: $e')),
      ),
    );
  }

  /// Evidence picked before saving; uploaded automatically right after the
  /// entry is created so the whole thing feels like one step.
  Widget _buildEvidenceSection() {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        border: Border.all(color: AppTheme.borderLight),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Evidence (photos/documents)',
            style: TextStyle(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 4),
          const Text(
            'Attach records supporting this entry (photos of damage, notices, etc.). '
            'Uploaded automatically when you save.',
            style: TextStyle(fontSize: 12, color: AppTheme.textSecondary),
          ),
          const SizedBox(height: 8),
          if (_pendingEvidence.isNotEmpty) ...[
            ..._pendingEvidence.asMap().entries.map((mapEntry) {
              final index = mapEntry.key;
              final evidence = mapEntry.value;
              return ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: Icon(
                  evidence.isPhoto ? Icons.image : Icons.description,
                  color: AppTheme.primaryBlue,
                ),
                title: Text(
                  evidence.filename,
                  overflow: TextOverflow.ellipsis,
                  maxLines: 1,
                  style: const TextStyle(fontSize: 13),
                ),
                subtitle: Text(
                  '${(evidence.bytes.length / 1024).toStringAsFixed(0)} KB',
                  style: const TextStyle(fontSize: 11),
                ),
                trailing: IconButton(
                  icon: const Icon(Icons.close, size: 18),
                  tooltip: 'Remove',
                  onPressed: _isLoading
                      ? null
                      : () => setState(() => _pendingEvidence.removeAt(index)),
                ),
              );
            }),
            const SizedBox(height: 4),
          ],
          OutlinedButton.icon(
            onPressed: _isLoading ? null : _pickEvidence,
            icon: const Icon(Icons.attach_file),
            label: const Text('Attach photo or document'),
          ),
        ],
      ),
    );
  }

  /// Who is filing this entry — attribution only, does not touch the subject fields.
  Widget _buildReportedByDropdown() {
    if (_staffLoading) {
      return const SizedBox(height: 4, child: LinearProgressIndicator());
    }
    if (_staffOptions.isEmpty) {
      return const SizedBox.shrink();
    }

    final style = AppTheme.dropdownItemTextStyle.copyWith(
      color: Theme.of(context).colorScheme.onSurface,
    );

    return DropdownButtonFormField<String>(
      value: _selectedStaffUserId,
      isExpanded: true,
      decoration: const InputDecoration(
        labelText: 'Reported by (staff member) *',
        helperText:
            'The staff member filing this entry. Recorded with the entry for accountability.',
        border: OutlineInputBorder(),
        prefixIcon: Icon(Icons.badge_outlined),
      ),
      selectedItemBuilder: (context) => _staffOptions
          .map(
            (option) => Text(
              '${option.displayName} (${option.roleLabel})',
              style: style,
              overflow: TextOverflow.ellipsis,
              maxLines: 1,
            ),
          )
          .toList(),
      items: _staffOptions
          .map(
            (option) => DropdownMenuItem<String>(
              value: option.userId,
              child: Text(
                '${option.displayName} (${option.roleLabel})'
                '${option.email.isNotEmpty ? ' \u2022 ${option.email}' : ''}',
                overflow: TextOverflow.ellipsis,
                maxLines: 1,
              ),
            ),
          )
          .toList(),
      onChanged: (value) => setState(() => _selectedStaffUserId = value),
    );
  }

  /// The tenant being placed on the DNR list — auto-fills the subject fields below.
  Widget _buildTenantLinkDropdown() {
    final facilityId = _selectedFacilityId;
    if (facilityId == null || facilityId.isEmpty) {
      return const SizedBox.shrink();
    }

    final tenantsAsync = ref.watch(facilityTenantsProvider(facilityId));

    return tenantsAsync.when(
      data: (tenants) {
        final style = AppTheme.dropdownItemTextStyle.copyWith(
          color: Theme.of(context).colorScheme.onSurface,
        );

        final hasSelectedTenant = _selectedTenantId != null &&
            tenants.any((tenant) => tenant.id == _selectedTenantId);
        final selectedValue = hasSelectedTenant ? _selectedTenantId! : '';

        return DropdownButtonFormField<String>(
          value: selectedValue,
          isExpanded: true,
          decoration: const InputDecoration(
            labelText: 'Link to tenant (optional)',
            helperText:
                'Selecting a tenant auto-fills their details below. Use Manual entry for someone who was never a tenant.',
            border: OutlineInputBorder(),
            prefixIcon: Icon(Icons.person_search),
          ),
          selectedItemBuilder: (context) => [
            Text('Manual entry', style: style, overflow: TextOverflow.ellipsis, maxLines: 1),
            ...tenants.map(
              (tenant) => Text(
                tenant.name,
                style: style,
                overflow: TextOverflow.ellipsis,
                maxLines: 1,
              ),
            ),
          ],
          items: [
            const DropdownMenuItem<String>(
              value: '',
              child: Text('Manual entry'),
            ),
            ...tenants.map(
              (tenant) => DropdownMenuItem<String>(
                value: tenant.id,
                child: Text(
                  '${tenant.name}${tenant.unitNumber.isNotEmpty ? ' \u2022 ${tenant.unitNumber}' : ''}',
                  overflow: TextOverflow.ellipsis,
                  maxLines: 1,
                ),
              ),
            ),
          ],
          onChanged: (value) => _applyTenantSelection(value, tenants),
        );
      },
      loading: () => const SizedBox(height: 4, child: LinearProgressIndicator()),
      error: (e, _) => Text(
        'Error loading tenants: $e',
        style: const TextStyle(color: AppTheme.error),
      ),
    );
  }

  Widget _buildFacilityDropdown(String userId) {
    final facilitiesAsync = ref.watch(userFacilitiesProvider(userId));
    return facilitiesAsync.when(
      data: (facilities) {
        if (facilities.isEmpty) {
          return Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: AppTheme.warning.withOpacity(0.1),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: AppTheme.warning),
            ),
            child: const Text(
              'No facilities found. Create a facility first.',
              style: TextStyle(color: AppTheme.textPrimary),
            ),
          );
        }
        final value = _selectedFacilityId ?? facilities.first.id;
        if (_selectedFacilityId == null && facilities.isNotEmpty) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) {
              setState(() => _selectedFacilityId = facilities.first.id);
              _loadStaffOptions(facilities.first.id);
            }
          });
        }
        final style = AppTheme.dropdownItemTextStyle.copyWith(
          color: Theme.of(context).colorScheme.onSurface,
        );
        return DropdownButtonFormField<String>(
          value: value,
          decoration: const InputDecoration(
            labelText: 'Facility (creating as) *',
            border: OutlineInputBorder(),
            prefixIcon: Icon(Icons.business),
          ),
          selectedItemBuilder: (context) => facilities
              .map((f) => Text(f.name, style: style, overflow: TextOverflow.ellipsis, maxLines: 1))
              .toList(),
          items: facilities.map((f) => DropdownMenuItem(value: f.id, child: Text(f.name))).toList(),
          onChanged: (v) {
            setState(() => _selectedFacilityId = v);
            if (v != null && v.isNotEmpty) {
              _loadStaffOptions(v);
            }
          },
        );
      },
      loading: () => const SizedBox(height: 4, child: LinearProgressIndicator()),
      error: (e, _) => Text('Error loading facilities: $e', style: const TextStyle(color: AppTheme.error)),
    );
  }
}
