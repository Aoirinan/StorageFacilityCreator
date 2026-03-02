import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../models/facility_model.dart';
import '../providers/auth_provider.dart';
import '../providers/facility_provider.dart';
import '../services/superadmin_service.dart';
import '../theme/app_theme.dart';
import '../services/texting_onboarding_service.dart';

class TextingSetupScreen extends ConsumerStatefulWidget {
  final String? facilityId;

  const TextingSetupScreen({super.key, this.facilityId});

  @override
  ConsumerState<TextingSetupScreen> createState() => _TextingSetupScreenState();
}

class _TextingSetupScreenState extends ConsumerState<TextingSetupScreen> {
  static const Duration _statusPollInterval = Duration(seconds: 30);

  int _step = 0;
  bool _busy = false;
  String? _error;
  Map<String, dynamic>? _status;
  String? _resolvedFacilityId;
  Timer? _statusTimer;

  final _legalName = TextEditingController();
  final _dba = TextEditingController();
  final _ein = TextEditingController();
  final _address1 = TextEditingController();
  final _city = TextEditingController();
  final _state = TextEditingController();
  final _postal = TextEditingController();
  final _website = TextEditingController();
  final _supportEmail = TextEditingController();
  final _supportPhone = TextEditingController();
  final _areaCode = TextEditingController();
  String _businessType = 'LLC';
  bool _consent = false;

  final Map<String, bool> _useCases = {
    'Late notices': true,
    'Payment reminders': true,
    'Gate code reminders': false,
    'Operational notices': false,
  };

  @override
  void dispose() {
    _statusTimer?.cancel();
    _legalName.dispose();
    _dba.dispose();
    _ein.dispose();
    _address1.dispose();
    _city.dispose();
    _state.dispose();
    _postal.dispose();
    _website.dispose();
    _supportEmail.dispose();
    _supportPhone.dispose();
    _areaCode.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    _statusTimer = Timer.periodic(_statusPollInterval, (_) {
      if (mounted && !_busy && _resolvedFacilityId != null) {
        _refreshStatus();
      }
    });
  }

  Future<void> _loadStatus() async {
    if (_resolvedFacilityId == null) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final status =
          await TextingOnboardingService.getStatus(_resolvedFacilityId!);
      if (mounted) {
        setState(() {
          _status = status;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e.toString();
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
        });
      }
    }
  }

  List<String> _selectedUseCases() {
    return _useCases.entries.where((e) => e.value).map((e) => e.key).toList();
  }

  List<String> _sampleMessages() {
    final samples = <String>[];
    if (_useCases['Late notices'] == true) {
      samples.add(
          'Your account is now past due. Please make payment to avoid late fees. Reply STOP to opt out.');
    }
    if (_useCases['Payment reminders'] == true) {
      samples.add(
          'Friendly reminder: your rent payment is due soon. Reply STOP to opt out.');
    }
    if (_useCases['Gate code reminders'] == true) {
      samples.add(
          'Reminder: your access code has been updated. Contact support for help. Reply STOP to opt out.');
    }
    if (_useCases['Operational notices'] == true) {
      samples.add(
          'Important facility notice: office hours update this week. Reply STOP to opt out.');
    }
    return samples;
  }

  Future<void> _saveBusinessInfo() async {
    if (_resolvedFacilityId == null) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await TextingOnboardingService.saveBusinessInfo(
        facilityId: _resolvedFacilityId!,
        businessData: {
          'legalBusinessName': _legalName.text.trim(),
          'dba': _dba.text.trim().isEmpty ? null : _dba.text.trim(),
          'businessType': _businessType,
          'ein': _ein.text.trim().isEmpty ? null : _ein.text.trim(),
          'addressLine1': _address1.text.trim(),
          'city': _city.text.trim(),
          'state': _state.text.trim(),
          'postalCode': _postal.text.trim(),
          'country': 'US',
          'website': _website.text.trim(),
          'supportEmail': _supportEmail.text.trim(),
          'supportPhone': _supportPhone.text.trim(),
        },
      );
      await _loadStatus();
      if (mounted) {
        setState(() => _step = 2);
      }
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _provisionNumber() async {
    if (_resolvedFacilityId == null) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await TextingOnboardingService.provisionPhoneNumber(
        facilityId: _resolvedFacilityId!,
        areaCode: _areaCode.text.trim().isEmpty ? null : _areaCode.text.trim(),
      );
      await _loadStatus();
      if (mounted) {
        setState(() => _step = 4);
      }
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _submit() async {
    if (_resolvedFacilityId == null) return;
    if (!_consent) {
      setState(
          () => _error = 'Consent confirmation is required before submitting.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await TextingOnboardingService.submitOnboarding(
        facilityId: _resolvedFacilityId!,
        useCases: _selectedUseCases(),
        sampleMessages: _sampleMessages(),
      );
      await _loadStatus();
      if (mounted) setState(() => _step = 5);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _refreshStatus() async {
    if (_resolvedFacilityId == null) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await TextingOnboardingService.refreshStatus(_resolvedFacilityId!);
      await _loadStatus();
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _resubmit() async {
    if (_resolvedFacilityId == null) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await TextingOnboardingService.resubmit(_resolvedFacilityId!);
      await _loadStatus();
      if (mounted) setState(() => _step = 4);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _setPlatformApproval(bool approved) async {
    if (_resolvedFacilityId == null) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await TextingOnboardingService.setPlatformApproval(
        facilityId: _resolvedFacilityId!,
        approved: approved,
      );
      await _loadStatus();
    } catch (e) {
      if (mounted) {
        setState(() => _error = e.toString());
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final userFacilities = ref.watch(
      userFacilitiesProvider(
        ref.watch(authStateProvider).whenOrNull(data: (u) => u?.uid) ?? '',
      ),
    );

    return Scaffold(
      appBar: AppBar(
        title: const Text('Enable Texting'),
        actions: [
          IconButton(
            onPressed: _busy ? null : _refreshStatus,
            icon: const Icon(Icons.refresh),
            tooltip: 'Refresh status',
          ),
        ],
      ),
      body: userFacilities.when(
        data: (facilities) {
          if (facilities.isEmpty) {
            return const Center(
                child: Text('Create a facility first to enable texting.'));
          }

          _resolvedFacilityId ??= widget.facilityId ?? facilities.first.id;
          final selectedFacility = facilities.firstWhere(
            (f) => f.id == _resolvedFacilityId,
            orElse: () => facilities.first,
          );
          _resolvedFacilityId = selectedFacility.id;
          _status ??= {
            'a2pStatus': selectedFacility.a2pStatus ?? 'draft',
            'twilioPhoneNumberE164': selectedFacility.twilioPhoneNumberE164,
            'a2pLastError': selectedFacility.a2pLastError,
          };

          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              if (_error != null) ...[
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.red.withOpacity(0.08),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child:
                      Text(_error!, style: const TextStyle(color: Colors.red)),
                ),
                const SizedBox(height: 12),
              ],
              _buildFacilitySelector(facilities),
              const SizedBox(height: 16),
              _buildStepper(context),
              if (_step >= 5) ...[
                const SizedBox(height: 24),
                _buildStatusCard(),
              ],
            ],
          );
        },
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Failed loading facilities: $e')),
      ),
    );
  }

  Widget _buildFacilitySelector(List<FacilityModel> facilities) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: DropdownButtonFormField<String>(
          value: _resolvedFacilityId,
          decoration: const InputDecoration(labelText: 'Facility'),
          items: facilities
              .map<DropdownMenuItem<String>>(
                (f) =>
                    DropdownMenuItem<String>(value: f.id, child: Text(f.name)),
              )
              .toList(),
          onChanged: _busy
              ? null
              : (value) {
                  setState(() {
                    _resolvedFacilityId = value;
                    _status = null;
                  });
                  _loadStatus();
                },
        ),
      ),
    );
  }

  Widget _buildStepper(BuildContext context) {
    return Stepper(
      currentStep: _step.clamp(0, 4),
      controlsBuilder: (_, __) => const SizedBox.shrink(),
      steps: [
        Step(
          title: const Text('Step 0: Intro'),
          isActive: _step == 0,
          content: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                  'Texting requires A2P review. Approval time varies by carrier.'),
              const SizedBox(height: 8),
              const Text(
                  'We provision a dedicated Twilio number for your facility. No number porting needed.'),
              const SizedBox(height: 12),
              ElevatedButton(
                onPressed: _busy ? null : () => setState(() => _step = 1),
                child: const Text('Start Setup'),
              ),
            ],
          ),
        ),
        Step(
          title: const Text('Step 1: Business Info'),
          isActive: _step == 1,
          content: Column(
            children: [
              _textField(_legalName, 'Legal business name *'),
              _textField(_dba, 'DBA (optional)'),
              DropdownButtonFormField<String>(
                value: _businessType,
                decoration: const InputDecoration(labelText: 'Business type *'),
                items: const [
                  DropdownMenuItem(value: 'LLC', child: Text('LLC')),
                  DropdownMenuItem(value: 'Corp', child: Text('Corp')),
                  DropdownMenuItem(
                      value: 'Nonprofit', child: Text('Nonprofit')),
                  DropdownMenuItem(
                      value: 'Sole Prop', child: Text('Sole Prop')),
                ],
                onChanged: _busy
                    ? null
                    : (v) => setState(() => _businessType = v ?? 'LLC'),
              ),
              _textField(
                  _ein,
                  _businessType == 'Sole Prop'
                      ? 'Tax ID last 4 (minimum)'
                      : 'EIN'),
              _textField(_address1, 'Business address *'),
              _textField(_city, 'City *'),
              _textField(_state, 'State *'),
              _textField(_postal, 'ZIP *'),
              _textField(_website, 'Website or app domain *'),
              _textField(_supportEmail, 'Support email *'),
              _textField(_supportPhone, 'Support phone *'),
              const SizedBox(height: 8),
              ElevatedButton(
                onPressed: _busy ? null : _saveBusinessInfo,
                child: const Text('Save Business Info'),
              ),
            ],
          ),
        ),
        Step(
          title: const Text('Step 2: Messaging Use Case'),
          isActive: _step == 2,
          content: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ..._useCases.keys.map((key) => CheckboxListTile(
                    value: _useCases[key] ?? false,
                    title: Text(key),
                    dense: true,
                    onChanged: _busy
                        ? null
                        : (v) => setState(() => _useCases[key] = v ?? false),
                  )),
              const SizedBox(height: 8),
              const Text('Sample message previews:'),
              const SizedBox(height: 8),
              ..._sampleMessages().map((m) => Text('- $m')),
              const SizedBox(height: 8),
              ElevatedButton(
                onPressed: _busy ? null : () => setState(() => _step = 3),
                child: const Text('Continue'),
              ),
            ],
          ),
        ),
        Step(
          title: const Text('Step 3: Phone Number'),
          isActive: _step == 3,
          content: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _textField(_areaCode, 'Preferred area code (optional)'),
              const SizedBox(height: 8),
              ElevatedButton(
                onPressed: _busy ? null : _provisionNumber,
                child: const Text('Provision Number'),
              ),
              if ((_status?['twilioPhoneNumberE164'] as String?)?.isNotEmpty ==
                  true) ...[
                const SizedBox(height: 8),
                Text('Selected number: ${_status?['twilioPhoneNumberE164']}'),
              ],
            ],
          ),
        ),
        Step(
          title: const Text('Step 4: Review & Submit'),
          isActive: _step == 4,
          content: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Business: ${_legalName.text.trim()}'),
              Text('Use cases: ${_selectedUseCases().join(', ')}'),
              Text(
                  'Phone: ${_status?['twilioPhoneNumberE164'] ?? 'Not provisioned'}'),
              const SizedBox(height: 8),
              CheckboxListTile(
                value: _consent,
                onChanged:
                    _busy ? null : (v) => setState(() => _consent = v ?? false),
                title: const Text(
                    'I confirm I have consent to text tenants for these account notifications.'),
                dense: true,
              ),
              ElevatedButton(
                onPressed: _busy ? null : _submit,
                child: const Text('Submit A2P Registration'),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildStatusCard() {
    final status = (_status?['a2pStatus'] as String?) ?? 'draft';
    final error = _status?['a2pLastError'] as String?;
    final rejectionReason = _status?['rejectionReason'] as String?;
    final isRejected = status.toLowerCase() == 'rejected';
    final isApprovedByCarrier = status.toLowerCase() == 'approved';
    final platformApproved = _status?['textingPlatformApproved'] == true;
    final isSuperAdmin = SuperAdminService.isSuperAdmin();
    final timeline = const ['draft', 'submitted', 'pending', 'approved'];
    final currentIndex = timeline.indexOf(status.toLowerCase());

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.sms_outlined, color: AppTheme.primaryBlue),
                const SizedBox(width: 8),
                Text('Texting Status: ${status.toUpperCase()}'),
              ],
            ),
            const SizedBox(height: 12),
            ...timeline.asMap().entries.map((entry) {
              final i = entry.key;
              final label = entry.value;
              final done = i <= currentIndex;
              return Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Row(
                  children: [
                    Icon(
                        done
                            ? Icons.check_circle
                            : Icons.radio_button_unchecked,
                        size: 16,
                        color: done ? Colors.green : Colors.grey),
                    const SizedBox(width: 8),
                    Text(label[0].toUpperCase() + label.substring(1)),
                  ],
                ),
              );
            }),
            if (isRejected || error != null || rejectionReason != null) ...[
              const SizedBox(height: 8),
              Text(
                'Latest issue: ${rejectionReason ?? error ?? 'Unknown'}',
                style: const TextStyle(color: Colors.red),
              ),
            ],
            if (isRejected) ...[
              const SizedBox(height: 8),
              OutlinedButton(
                onPressed: _busy ? null : _resubmit,
                child: const Text('Resubmit'),
              ),
            ],
            if (isApprovedByCarrier) ...[
              const SizedBox(height: 8),
              Text(
                platformApproved
                    ? 'Platform approval: Approved'
                    : 'Platform approval: Pending superadmin acceptance',
                style: TextStyle(
                  color: platformApproved ? Colors.green : Colors.orange,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
            if (isSuperAdmin && isApprovedByCarrier) ...[
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                children: [
                  OutlinedButton(
                    onPressed: _busy ? null : () => _setPlatformApproval(true),
                    child: const Text('Accept For SMS Sending'),
                  ),
                  OutlinedButton(
                    onPressed: _busy ? null : () => _setPlatformApproval(false),
                    child: const Text('Revoke Approval'),
                  ),
                ],
              ),
            ],
            const SizedBox(height: 4),
            const Text(
              'Status auto-refreshes every 30 seconds.',
              style: TextStyle(fontSize: 12, color: Colors.grey),
            ),
          ],
        ),
      ),
    );
  }

  Widget _textField(TextEditingController controller, String label) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: TextField(
        controller: controller,
        decoration: InputDecoration(labelText: label),
      ),
    );
  }
}
