import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/global_dnr_model.dart';
import '../models/permission_model.dart';
import '../providers/auth_provider.dart';
import '../providers/facility_provider.dart';
import '../models/facility_model.dart';
import '../services/dnr_terms_service.dart';
import '../services/global_dnr_service.dart';
import '../services/facility_service.dart';
import '../services/permission_service.dart';
import '../theme/app_theme.dart';
import '../widgets/modern_page_wrapper.dart';

/// A selectable person (facility staff member) used to auto-fill the entry form.
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

  /// Load the facility's staff (owner/manager/employee) for the person dropdown.
  Future<void> _loadStaffOptions(String facilityId) async {
    setState(() {
      _staffLoading = true;
      _staffOptions = [];
      _selectedStaffUserId = null;
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
      });
    }
  }

  void _applyStaffSelection(String? userId) {
    setState(() => _selectedStaffUserId = userId);
    if (userId == null) return;
    _StaffOption? match;
    for (final option in _staffOptions) {
      if (option.userId == userId) {
        match = option;
        break;
      }
    }
    if (match == null) return;
    _fullNameController.text = match.displayName;
    _emailController.text = match.email;
    if (match.phone != null && match.phone!.isNotEmpty) {
      _phoneController.text = match.phone!;
    }
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

      await GlobalDNRService.createGlobalDNREntry(
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
      );

      if (mounted) {
        Navigator.of(context).pop(true);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Global DNR entry created'), backgroundColor: AppTheme.success),
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isLoading = false;
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
                  _buildPersonDropdown(),
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
                        ? const SizedBox(
                            height: 24,
                            width: 24,
                            child: CircularProgressIndicator(strokeWidth: 2, color: AppTheme.textOnDark),
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

  Widget _buildPersonDropdown() {
    if (_staffLoading) {
      return const SizedBox(height: 4, child: LinearProgressIndicator());
    }

    final style = AppTheme.dropdownItemTextStyle.copyWith(
      color: Theme.of(context).colorScheme.onSurface,
    );

    final items = <DropdownMenuItem<String?>>[
      const DropdownMenuItem<String?>(
        value: null,
        child: Text('Manual entry'),
      ),
      ..._staffOptions.map(
        (option) => DropdownMenuItem<String?>(
          value: option.userId,
          child: Text(
            '${option.displayName} (${option.roleLabel})'
            '${option.email.isNotEmpty ? ' \u2022 ${option.email}' : ''}',
            overflow: TextOverflow.ellipsis,
            maxLines: 1,
          ),
        ),
      ),
    ];

    return DropdownButtonFormField<String?>(
      value: _selectedStaffUserId,
      isExpanded: true,
      decoration: const InputDecoration(
        labelText: 'Select person',
        helperText:
            'Choose a staff member to auto-fill their details below, or use Manual entry.',
        border: OutlineInputBorder(),
        prefixIcon: Icon(Icons.person_search),
      ),
      selectedItemBuilder: (context) => [
        Text('Manual entry', style: style, overflow: TextOverflow.ellipsis, maxLines: 1),
        ..._staffOptions.map(
          (option) => Text(
            '${option.displayName} (${option.roleLabel})',
            style: style,
            overflow: TextOverflow.ellipsis,
            maxLines: 1,
          ),
        ),
      ],
      items: items,
      onChanged: _applyStaffSelection,
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
