import 'dart:async';
import 'dart:math' show min;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:sfcapp/models/facility_model.dart';
import 'package:sfcapp/providers/auth_provider.dart';
import 'package:sfcapp/providers/facility_provider.dart';
import 'package:sfcapp/services/superadmin_service.dart';
import 'package:sfcapp/services/texting_onboarding_service.dart';
import 'package:sfcapp/theme/app_theme.dart';
import 'package:sfcapp/widgets/keyboard_scrollable.dart';

class TextingSetupScreen extends ConsumerStatefulWidget {
  final String? facilityId;

  const TextingSetupScreen({super.key, this.facilityId});

  @override
  ConsumerState<TextingSetupScreen> createState() => _TextingSetupScreenState();
}

class _TextingSetupScreenState extends ConsumerState<TextingSetupScreen> {
  static const Duration _statusPollInterval = Duration(seconds: 30);

  static const List<String> _stepTitles = [
    'Welcome',
    'Business information',
    'Messaging use cases',
    'Dedicated phone number',
    'Review and submit',
  ];

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
            icon: const Icon(Icons.refresh_rounded),
            tooltip: 'Refresh status',
          ),
        ],
      ),
      body: userFacilities.when(
        data: (facilities) {
          if (facilities.isEmpty) {
            return _buildEmptyState(context);
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

          return LayoutBuilder(
            builder: (context, constraints) {
              final maxW = min(constraints.maxWidth, 720.0);
              return Align(
                alignment: Alignment.topCenter,
                child: SizedBox(
                  width: maxW,
                  child: KeyboardScrollable(
                    child: ListView(
                      padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
                      children: [
                        if (_error != null) ...[
                          _buildErrorBanner(context),
                          const SizedBox(height: 16),
                        ],
                        _buildFacilitySelector(context, facilities),
                        const SizedBox(height: 20),
                        if (_step < 5) _buildWizardCard(context),
                        if (_step >= 5) ...[
                          _buildSubmittedHeader(context),
                          const SizedBox(height: 16),
                          _buildStatusCard(context),
                        ],
                      ],
                    ),
                  ),
                ),
              );
            },
          );
        },
        loading: () => Center(
          child: CircularProgressIndicator(
            color: Theme.of(context).colorScheme.primary,
          ),
        ),
        error: (e, _) => _buildLoadError(context, e),
      ),
    );
  }

  Widget _buildEmptyState(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 400),
        child: Card(
          child: Padding(
            padding: const EdgeInsets.all(28),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.business_outlined, size: 48, color: cs.primary),
                const SizedBox(height: 16),
                Text(
                  'Create a facility first',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'SMS setup is per facility. Add a facility, then return here to enable texting.',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: cs.onSurfaceVariant,
                    height: 1.45,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildLoadError(BuildContext context, Object e) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 440),
        child: Card(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.cloud_off_outlined, size: 40, color: cs.error),
                const SizedBox(height: 12),
                Text(
                  'Could not load facilities',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 8),
                SelectableText(
                  '$e',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: cs.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildErrorBanner(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Material(
      color: cs.error.withValues(alpha: 0.08),
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.error_outline_rounded, color: cs.error, size: 24),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                _error!,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: cs.error,
                      height: 1.35,
                    ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildFacilitySelector(
      BuildContext context, List<FacilityModel> facilities) {
    final id = _resolvedFacilityId;
    if (id == null) return const SizedBox.shrink();

    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
        child: DropdownMenuFormField<String>(
          key: ValueKey<String>(id),
          initialSelection: id,
          enabled: !_busy,
          width: double.infinity,
          enableSearch: facilities.length > 6,
          menuHeight: min(320, MediaQuery.sizeOf(context).height * 0.4),
          label: const Text('Facility'),
          leadingIcon: const Icon(Icons.business_outlined),
          onSelected: (value) {
            if (value == null) return;
            setState(() {
              _resolvedFacilityId = value;
              _status = null;
            });
            _loadStatus();
          },
          dropdownMenuEntries: [
            for (final f in facilities)
              DropdownMenuEntry<String>(value: f.id, label: f.name),
          ],
        ),
      ),
    );
  }

  Widget _buildWizardCard(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _buildStepProgress(context),
            const SizedBox(height: 24),
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 200),
              switchInCurve: Curves.easeOut,
              switchOutCurve: Curves.easeIn,
              child: KeyedSubtree(
                key: ValueKey<int>(_step),
                child: _buildStepBody(context),
              ),
            ),
            if (_busy) ...[
              const SizedBox(height: 20),
              const Center(child: LinearProgressIndicator(minHeight: 3)),
            ],
            if (_step > 0 && _step < 5) ...[
              const SizedBox(height: 16),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: _busy
                      ? null
                      : () => setState(() => _step = _step - 1),
                  icon: const Icon(Icons.arrow_back_rounded, size: 18),
                  label: const Text('Back'),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildSubmittedHeader(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: cs.primary.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(Icons.mark_email_read_outlined, color: cs.primary),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Registration submitted',
                    style: theme.textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'Carrier review can take some time. We will keep status updated below.',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: cs.onSurfaceVariant,
                      height: 1.4,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStepSegments(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final idx = _step.clamp(0, 4);
    return Semantics(
      label: 'Setup progress, step ${idx + 1} of 5',
      child: Row(
        children: List.generate(5, (i) {
          final done = i < idx;
          final active = i == idx;
          final Color segColor;
          if (done) {
            segColor = cs.primary;
          } else if (active) {
            segColor = cs.primary.withValues(alpha: 0.55);
          } else {
            segColor = cs.outlineVariant.withValues(alpha: 0.45);
          }
          return Expanded(
            child: Padding(
              padding: EdgeInsets.only(right: i < 4 ? 5 : 0),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 220),
                curve: Curves.easeOutCubic,
                height: 5,
                decoration: BoxDecoration(
                  color: segColor,
                  borderRadius: BorderRadius.circular(3),
                ),
              ),
            ),
          );
        }),
      ),
    );
  }

  Widget _buildStepProgress(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final idx = _step.clamp(0, 4);
    const total = 5;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Step ${idx + 1} of $total',
          style: theme.textTheme.labelLarge?.copyWith(
            color: cs.primary,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.2,
          ),
        ),
        const SizedBox(height: 10),
        ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: LinearProgressIndicator(
            value: (idx + 1) / total,
            minHeight: 8,
            backgroundColor:
                cs.surfaceContainerHighest.withValues(alpha: 0.85),
            color: cs.primary,
          ),
        ),
        const SizedBox(height: 12),
        _buildStepSegments(context),
        const SizedBox(height: 16),
        Text(
          _stepTitles[idx],
          style: theme.textTheme.headlineSmall?.copyWith(
            fontWeight: FontWeight.w700,
            letterSpacing: -0.4,
            color: cs.onSurface,
          ),
        ),
      ],
    );
  }

  Widget _buildStepBody(BuildContext context) {
    switch (_step) {
      case 0:
        return _buildIntroStep(context);
      case 1:
        return _buildBusinessStep(context);
      case 2:
        return _buildUseCaseStep(context);
      case 3:
        return _buildPhoneStep(context);
      case 4:
        return _buildReviewStep(context);
      default:
        return const SizedBox.shrink();
    }
  }

  Widget _buildIntroStep(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final bullets = [
      'A2P 10DLC registration is required; approval timing depends on carriers.',
      'We provision a dedicated SMS number for this facility—no porting required.',
      'Outbound texting stays compliant with the use cases you select in the next steps.',
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                color: cs.primary.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(14),
              ),
              child: Icon(Icons.sms_outlined, color: cs.primary, size: 26),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Text(
                'Turn on SMS for payment reminders, delinquency notices, and operational updates tenants expect.',
                style: theme.textTheme.bodyLarge?.copyWith(
                  height: 1.45,
                  color: cs.onSurfaceVariant,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 20),
        ...bullets.map(
          (line) => Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  Icons.check_circle_outline_rounded,
                  size: 22,
                  color: cs.primary.withValues(alpha: 0.85),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    line,
                    style: theme.textTheme.bodyMedium?.copyWith(height: 1.4),
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 8),
        FilledButton(
          onPressed: _busy ? null : () => setState(() => _step = 1),
          child: const Text('Start setup'),
        ),
      ],
    );
  }

  Widget _buildBusinessStep(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'This should match your legal business profile for carrier registration.',
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
                height: 1.4,
              ),
        ),
        const SizedBox(height: 16),
        AutofillGroup(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _textField(
                _legalName,
                'Legal business name *',
                autofillHints: const [AutofillHints.organizationName],
              ),
              _textField(
                _dba,
                'DBA (optional)',
                autofillHints: const [AutofillHints.name],
              ),
              DropdownMenuFormField<String>(
                key: ValueKey<String>(_businessType),
                initialSelection: _businessType,
                enabled: !_busy,
                width: double.infinity,
                enableSearch: false,
                label: const Text('Business type *'),
                onSelected: (v) =>
                    setState(() => _businessType = v ?? 'LLC'),
                dropdownMenuEntries: const [
                  DropdownMenuEntry(value: 'LLC', label: 'LLC'),
                  DropdownMenuEntry(value: 'Corp', label: 'Corp'),
                  DropdownMenuEntry(value: 'Nonprofit', label: 'Nonprofit'),
                  DropdownMenuEntry(value: 'Sole Prop', label: 'Sole Prop'),
                ],
              ),
              const SizedBox(height: 8),
              _textField(
                _ein,
                _businessType == 'Sole Prop'
                    ? 'Tax ID last 4 (minimum)'
                    : 'EIN',
              ),
              _textField(
                _address1,
                'Business address *',
                autofillHints: const [AutofillHints.streetAddressLine1],
              ),
              _textField(
                _city,
                'City *',
                autofillHints: const [AutofillHints.addressCity],
              ),
              _textField(
                _state,
                'State *',
                autofillHints: const [AutofillHints.addressState],
              ),
              _textField(
                _postal,
                'ZIP *',
                autofillHints: const [AutofillHints.postalCode],
              ),
              _textField(
                _website,
                'Website or app domain *',
                autofillHints: const [AutofillHints.url],
                keyboardType: TextInputType.url,
              ),
              _textField(
                _supportEmail,
                'Support email *',
                autofillHints: const [AutofillHints.email],
                keyboardType: TextInputType.emailAddress,
              ),
              _textField(
                _supportPhone,
                'Support phone *',
                autofillHints: const [AutofillHints.telephoneNumber],
                keyboardType: TextInputType.phone,
                textInputAction: TextInputAction.done,
              ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        FilledButton(
          onPressed: _busy ? null : _saveBusinessInfo,
          child: const Text('Save and continue'),
        ),
      ],
    );
  }

  Widget _buildUseCaseStep(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final samples = _sampleMessages();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Choose the types of messages you will send. Sample previews help carriers understand your program.',
          style: theme.textTheme.bodyMedium?.copyWith(
            color: cs.onSurfaceVariant,
            height: 1.4,
          ),
        ),
        const SizedBox(height: 8),
        ..._useCases.keys.map(
          (key) => CheckboxListTile(
            value: _useCases[key] ?? false,
            title: Text(key, style: theme.textTheme.titleSmall),
            contentPadding: EdgeInsets.zero,
            controlAffinity: ListTileControlAffinity.leading,
            onChanged: _busy
                ? null
                : (v) => setState(() => _useCases[key] = v ?? false),
          ),
        ),
        const SizedBox(height: 12),
        Text(
          'Sample message previews',
          style: theme.textTheme.titleSmall?.copyWith(
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 8),
        ...samples.map(
          (m) => Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Material(
              color: cs.surfaceContainerHighest.withValues(alpha: 0.45),
              borderRadius: BorderRadius.circular(10),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                child: Text(
                  m,
                  style: theme.textTheme.bodySmall?.copyWith(height: 1.45),
                ),
              ),
            ),
          ),
        ),
        const SizedBox(height: 8),
        FilledButton(
          onPressed: _busy ? null : () => setState(() => _step = 3),
          child: const Text('Continue'),
        ),
      ],
    );
  }

  Widget _buildPhoneStep(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final e164 = _status?['twilioPhoneNumberE164'] as String?;
    final hasNumber = e164 != null && e164.isNotEmpty;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'We will purchase a US local SMS-capable number and attach it to your facility.',
          style: theme.textTheme.bodyMedium?.copyWith(
            color: cs.onSurfaceVariant,
            height: 1.4,
          ),
        ),
        const SizedBox(height: 16),
        _textField(_areaCode, 'Preferred area code (optional)'),
        const SizedBox(height: 4),
        FilledButton(
          onPressed: _busy ? null : _provisionNumber,
          child: const Text('Provision number'),
        ),
        if (hasNumber) ...[
          const SizedBox(height: 16),
          Material(
            color: cs.primary.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(10),
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Row(
                children: [
                  Icon(Icons.phone_android_rounded, color: cs.primary),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Selected number',
                          style: theme.textTheme.labelMedium?.copyWith(
                            color: cs.onSurfaceVariant,
                          ),
                        ),
                        const SizedBox(height: 2),
                        SelectableText(
                          e164,
                          style: theme.textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildReviewStep(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final phoneLine =
        (_status?['twilioPhoneNumberE164'] as String?)?.trim().isNotEmpty == true
            ? (_status!['twilioPhoneNumberE164'] as String)
            : 'Not provisioned';
    Widget row(String label, String value) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              label,
              style: theme.textTheme.labelMedium?.copyWith(
                color: cs.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 4),
            SelectableText(
              value,
              style: theme.textTheme.bodyLarge?.copyWith(
                fontWeight: FontWeight.w500,
                height: 1.35,
              ),
            ),
          ],
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Confirm details before we submit your A2P registration.',
          style: theme.textTheme.bodyMedium?.copyWith(
            color: cs.onSurfaceVariant,
            height: 1.4,
          ),
        ),
        const SizedBox(height: 16),
        row('Business', _legalName.text.trim()),
        row('Use cases', _selectedUseCases().join(', ')),
        row('Phone', phoneLine),
        CheckboxListTile(
          value: _consent,
          contentPadding: EdgeInsets.zero,
          controlAffinity: ListTileControlAffinity.leading,
          onChanged:
              _busy ? null : (v) => setState(() => _consent = v ?? false),
          title: Text(
            'I confirm I have consent to text tenants for these account notifications.',
            style: theme.textTheme.bodyMedium?.copyWith(height: 1.4),
          ),
        ),
        const SizedBox(height: 4),
        FilledButton(
          onPressed: _busy ? null : _submit,
          child: const Text('Submit A2P registration'),
        ),
      ],
    );
  }

  Widget _buildStatusCard(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
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
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.sms_outlined, color: cs.primary),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Texting status · ${status.toUpperCase()}',
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            ...timeline.asMap().entries.map((entry) {
              final i = entry.key;
              final label = entry.value;
              final done = i <= currentIndex;
              return Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Row(
                  children: [
                    Icon(
                      done
                          ? Icons.check_circle_rounded
                          : Icons.radio_button_unchecked,
                      size: 18,
                      color: done ? AppTheme.success : cs.onSurfaceVariant,
                    ),
                    const SizedBox(width: 10),
                    Text(
                      label[0].toUpperCase() + label.substring(1),
                      style: theme.textTheme.bodyMedium?.copyWith(
                        fontWeight:
                            done ? FontWeight.w600 : FontWeight.w400,
                        color: done ? cs.onSurface : cs.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              );
            }),
            if (isRejected || error != null || rejectionReason != null) ...[
              const SizedBox(height: 8),
              Text(
                'Latest issue: ${rejectionReason ?? error ?? 'Unknown'}',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: cs.error,
                  height: 1.35,
                ),
              ),
            ],
            if (isRejected) ...[
              const SizedBox(height: 12),
              OutlinedButton(
                onPressed: _busy ? null : _resubmit,
                child: const Text('Resubmit'),
              ),
            ],
            if (isApprovedByCarrier) ...[
              const SizedBox(height: 12),
              Text(
                platformApproved
                    ? 'Platform approval: Approved'
                    : 'Platform approval: Pending superadmin acceptance',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: platformApproved ? AppTheme.success : AppTheme.warning,
                  fontWeight: FontWeight.w600,
                  height: 1.35,
                ),
              ),
            ],
            if (isSuperAdmin && isApprovedByCarrier) ...[
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  OutlinedButton(
                    onPressed: _busy ? null : () => _setPlatformApproval(true),
                    child: const Text('Accept for SMS sending'),
                  ),
                  OutlinedButton(
                    onPressed: _busy ? null : () => _setPlatformApproval(false),
                    child: const Text('Revoke approval'),
                  ),
                ],
              ),
            ],
            const SizedBox(height: 12),
            Text(
              'Status auto-refreshes every 30 seconds.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: cs.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _textField(
    TextEditingController controller,
    String label, {
    List<String>? autofillHints,
    TextInputType? keyboardType,
    TextInputAction textInputAction = TextInputAction.next,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: TextField(
        controller: controller,
        autofillHints: autofillHints,
        keyboardType: keyboardType,
        textInputAction: textInputAction,
        onSubmitted: textInputAction == TextInputAction.next
            ? (_) => FocusScope.of(context).nextFocus()
            : (_) => FocusScope.of(context).unfocus(),
        decoration: InputDecoration(labelText: label),
      ),
    );
  }
}
