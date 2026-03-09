import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/global_dnr_model.dart';
import '../providers/auth_provider.dart';
import '../providers/facility_provider.dart';
import '../models/facility_model.dart';
import '../services/global_dnr_service.dart';
import '../services/facility_service.dart';
import '../theme/app_theme.dart';

/// Form to add a new entry to the Global DNR collection (shared across all facilities).
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
  bool _isLoading = false;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _setDefaultFacility();
  }

  Future<void> _setDefaultFacility() async {
    final fid = await GlobalDNRService.getCurrentUserFirstFacilityId();
    if (mounted && fid != null) setState(() => _selectedFacilityId = fid);
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
          return Scaffold(
            appBar: AppBar(title: const Text('Add to Global DNR')),
            body: const Center(child: Text('Please sign in to add a Global DNR entry.')),
          );
        }
        return Scaffold(
          appBar: AppBar(
            title: const Text('Add to Global DNR'),
            leading: IconButton(
              icon: const Icon(Icons.arrow_back),
              onPressed: () => Navigator.of(context).pop(),
            ),
          ),
          body: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: Form(
              key: _formKey,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text(
                    'This entry will be visible to all facilities. Only add individuals who should not be rented to across the network.',
                    style: TextStyle(color: AppTheme.textSecondary, fontSize: 12),
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
        );
      },
      loading: () => const Scaffold(body: Center(child: CircularProgressIndicator())),
      error: (e, _) => Scaffold(
        appBar: AppBar(title: const Text('Add to Global DNR')),
        body: Center(child: Text('Error: $e')),
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
            if (mounted) setState(() => _selectedFacilityId = facilities.first.id);
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
          onChanged: (v) => setState(() => _selectedFacilityId = v),
        );
      },
      loading: () => const SizedBox(height: 4, child: LinearProgressIndicator()),
      error: (e, _) => Text('Error loading facilities: $e', style: const TextStyle(color: AppTheme.error)),
    );
  }
}
