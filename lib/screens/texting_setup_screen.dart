import 'dart:async';
import 'dart:math' show min;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import 'package:sfcapp/controllers/texting_onboarding_controller.dart';
import 'package:sfcapp/models/facility_model.dart';
import 'package:sfcapp/models/texting_onboarding_model.dart';
import 'package:sfcapp/providers/auth_provider.dart';
import 'package:sfcapp/providers/facility_provider.dart';
import 'package:sfcapp/services/superadmin_service.dart';
import 'package:sfcapp/services/texting_onboarding_service.dart';
import 'package:sfcapp/theme/app_theme.dart';
import 'package:sfcapp/widgets/keyboard_scrollable.dart';

class TextingSetupScreen extends ConsumerStatefulWidget {
  final String? facilityId;
  final TextingOnboardingRepository? repository;
  final bool? isSuperAdminOverride;
  final List<FacilityModel>? facilitiesOverride;

  const TextingSetupScreen({
    super.key,
    this.facilityId,
    this.repository,
    this.isSuperAdminOverride,
    this.facilitiesOverride,
  });

  @override
  ConsumerState<TextingSetupScreen> createState() => _TextingSetupScreenState();
}

class _TextingSetupScreenState extends ConsumerState<TextingSetupScreen> {
  static const _pollInterval = Duration(seconds: 30);
  static const _stepTitles = [
    'Business details',
    'Messaging plan',
    'Review & submit',
  ];

  late final TextingOnboardingController _controller;
  Timer? _pollTimer;
  String? _hydratedFacilityId;

  final _businessFormKey = GlobalKey<FormState>();
  final _reviewFormKey = GlobalKey<FormState>();
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
    'Payment reminders': true,
    'Past-due notices': true,
    'Gate and access updates': false,
    'Operational notices': false,
  };

  @override
  void initState() {
    super.initState();
    _controller = TextingOnboardingController(
      repository: widget.repository ?? FirebaseTextingOnboardingRepository(),
    )..addListener(_onControllerChanged);
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    _controller
      ..removeListener(_onControllerChanged)
      ..dispose();
    for (final textController in [
      _legalName,
      _dba,
      _ein,
      _address1,
      _city,
      _state,
      _postal,
      _website,
      _supportEmail,
      _supportPhone,
      _areaCode,
    ]) {
      textController.dispose();
    }
    super.dispose();
  }

  void _onControllerChanged() {
    if (!mounted) return;
    final snapshot = _controller.snapshot;
    final facilityId = _controller.facilityId;
    if (snapshot != null &&
        facilityId != null &&
        _hydratedFacilityId != facilityId) {
      _hydrate(snapshot);
      _hydratedFacilityId = facilityId;
    }
    _syncPolling();
    setState(() {});
  }

  void _syncPolling() {
    if (_controller.shouldPoll) {
      _pollTimer ??= Timer.periodic(
        _pollInterval,
        (_) => _controller.refresh(poll: true),
      );
    } else {
      _pollTimer?.cancel();
      _pollTimer = null;
    }
  }

  void _hydrate(TextingOnboardingSnapshot snapshot) {
    final details = snapshot.businessDetails;
    if (details != null) {
      _legalName.text = details.legalBusinessName;
      _dba.text = details.dba ?? '';
      _businessType =
          const {'LLC', 'Corp', 'Nonprofit'}.contains(details.businessType)
              ? details.businessType
              : 'LLC';
      _address1.text = details.addressLine1;
      _city.text = details.city;
      _state.text = details.state;
      _postal.text = details.postalCode;
      _website.text = details.website;
      _supportEmail.text = details.supportEmail;
      _supportPhone.text = details.supportPhone;
    }
    if (snapshot.useCases.isNotEmpty) {
      final savedUseCases = snapshot.useCases.map((useCase) {
        return switch (useCase) {
          'Late notices' => 'Past-due notices',
          'Gate code reminders' => 'Gate and access updates',
          _ => useCase,
        };
      }).toSet();
      for (final key in _useCases.keys) {
        _useCases[key] = savedUseCases.contains(key);
      }
    }
  }

  void _ensureInitialFacility(List<FacilityModel> facilities) {
    if (facilities.isEmpty || _controller.facilityId != null) return;
    final requested = widget.facilityId;
    final selected = facilities.firstWhere(
      (facility) => facility.id == requested,
      orElse: () => facilities.first,
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _controller.facilityId == null) {
        _controller.load(selected.id);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final facilitiesOverride = widget.facilitiesOverride;
    final uid = facilitiesOverride == null
        ? ref.watch(authStateProvider).whenOrNull(data: (user) => user?.uid) ??
            ''
        : '';
    final AsyncValue<List<FacilityModel>> facilitiesAsync =
        facilitiesOverride != null
            ? AsyncValue.data(facilitiesOverride)
            : ref.watch(userFacilitiesProvider(uid));

    return Scaffold(
      appBar: AppBar(
        title: const Text('Texting'),
        actions: [
          IconButton(
            tooltip: 'Refresh texting status',
            onPressed: _controller.isWorking || _controller.facilityId == null
                ? null
                : _controller.refresh,
            icon: const Icon(Icons.refresh_rounded),
          ),
        ],
      ),
      body: facilitiesAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (_, __) => _LoadFailure(
            onRetry: () => ref.invalidate(
                  userFacilitiesProvider(uid),
                )),
        data: (facilities) {
          if (facilities.isEmpty) return const _NoFacilities();
          _ensureInitialFacility(facilities);
          return _buildBody(facilities);
        },
      ),
    );
  }

  Widget _buildBody(List<FacilityModel> facilities) {
    if (_controller.isLoading || _controller.facilityId == null) {
      return const _SetupSkeleton();
    }

    return KeyboardScrollable(
      child: ListView(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 48),
        children: [
          Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 1080),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _PageHeader(
                    facilities: facilities,
                    selectedFacilityId: _controller.facilityId!,
                    enabled: !_controller.isWorking,
                    onSelected: (facilityId) {
                      if (facilityId == null ||
                          facilityId == _controller.facilityId) {
                        return;
                      }
                      _hydratedFacilityId = null;
                      _consent = false;
                      _controller.load(facilityId);
                    },
                  ),
                  if (_controller.errorMessage != null) ...[
                    const SizedBox(height: 16),
                    _ErrorBanner(
                      message: _controller.errorMessage!,
                      onDismiss: _controller.clearError,
                    ),
                  ],
                  const SizedBox(height: 20),
                  if (_controller.showDashboard)
                    _buildStatusDashboard()
                  else
                    _buildGuidedSetup(),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildGuidedSetup() {
    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth >= 840;
        final rail = _StepRail(
          currentStep: _controller.step,
          onStepSelected: _controller.isWorking
              ? null
              : (step) {
                  if (step <= _controller.step) _controller.goToStep(step);
                },
          horizontal: !wide,
        );
        final card = Card(
          margin: EdgeInsets.zero,
          child: Padding(
            padding: EdgeInsets.all(wide ? 28 : 20),
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 180),
              child: KeyedSubtree(
                key: ValueKey(_controller.step),
                child: switch (_controller.step) {
                  0 => _buildBusinessStage(),
                  1 => _buildMessagingStage(),
                  _ => _buildReviewStage(),
                },
              ),
            ),
          ),
        );

        if (!wide) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              rail,
              const SizedBox(height: 16),
              card,
            ],
          );
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(width: 250, child: rail),
            const SizedBox(width: 20),
            Expanded(child: card),
          ],
        );
      },
    );
  }

  Widget _buildBusinessStage() {
    final locked = _controller.snapshot?.hasTrustProfile == true;
    return Form(
      key: _businessFormKey,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const _StageHeading(
            eyebrow: 'STEP 1 OF 3',
            title: 'Tell us about your business',
            description:
                'Carriers verify these details against public and tax records. Enter the legal information exactly as registered.',
          ),
          if (locked) ...[
            const SizedBox(height: 20),
            const _InfoCallout(
              icon: Icons.lock_outline_rounded,
              title: 'Business profile saved',
              message:
                  'These details are locked after the carrier profile is created. Contact SFC support if something needs to change.',
            ),
          ],
          const SizedBox(height: 24),
          _SectionLabel('Business identity'),
          const SizedBox(height: 12),
          _field(
            key: const Key('legal-business-name'),
            controller: _legalName,
            label: 'Legal business name',
            enabled: !locked,
            validator: _required('Enter the legal business name.'),
            autofillHints: const [AutofillHints.organizationName],
          ),
          const SizedBox(height: 12),
          _field(
            controller: _dba,
            label: 'Doing business as (optional)',
            enabled: !locked,
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<String>(
            initialValue: _businessType,
            decoration: const InputDecoration(labelText: 'Business type'),
            items: const [
              DropdownMenuItem(value: 'LLC', child: Text('LLC')),
              DropdownMenuItem(value: 'Corp', child: Text('Corporation')),
              DropdownMenuItem(
                value: 'Nonprofit',
                child: Text('Nonprofit'),
              ),
            ],
            onChanged: locked
                ? null
                : (value) => setState(() => _businessType = value ?? 'LLC'),
          ),
          const SizedBox(height: 12),
          _field(
            key: const Key('ein'),
            controller: _ein,
            label: locked
                ? 'EIN ending in ${_controller.snapshot?.businessDetails?.einLast4 ?? '••••'}'
                : 'Federal EIN',
            hint: locked ? null : '12-3456789',
            enabled: !locked,
            keyboardType: TextInputType.number,
            validator: locked
                ? null
                : (value) {
                    final digits = _digits(value);
                    return digits.length == 9
                        ? null
                        : 'Enter a valid 9-digit EIN.';
                  },
          ),
          const SizedBox(height: 12),
          const _InfoCallout(
            icon: Icons.info_outline_rounded,
            title: 'Sole proprietor?',
            message:
                'Sole proprietor registrations require manual carrier setup. Contact SFC support instead of continuing here.',
          ),
          const SizedBox(height: 24),
          _SectionLabel('Registered address'),
          const SizedBox(height: 12),
          _field(
            controller: _address1,
            label: 'Street address',
            enabled: !locked,
            validator: _required('Enter the registered street address.'),
            autofillHints: const [AutofillHints.streetAddressLine1],
          ),
          const SizedBox(height: 12),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                flex: 2,
                child: _field(
                  controller: _city,
                  label: 'City',
                  enabled: !locked,
                  validator: _required('Enter a city.'),
                  autofillHints: const [AutofillHints.addressCity],
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _field(
                  controller: _state,
                  label: 'State',
                  hint: 'TX',
                  enabled: !locked,
                  textCapitalization: TextCapitalization.characters,
                  validator: (value) =>
                      RegExp(r'^[A-Za-z]{2}$').hasMatch(value?.trim() ?? '')
                          ? null
                          : 'Use 2 letters.',
                  autofillHints: const [AutofillHints.addressState],
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _field(
                  controller: _postal,
                  label: 'ZIP',
                  enabled: !locked,
                  keyboardType: TextInputType.number,
                  validator: (value) =>
                      RegExp(r'^\d{5}(-\d{4})?$').hasMatch(value?.trim() ?? '')
                          ? null
                          : 'Enter a valid ZIP.',
                  autofillHints: const [AutofillHints.postalCode],
                ),
              ),
            ],
          ),
          const SizedBox(height: 24),
          _SectionLabel('Public contact details'),
          const SizedBox(height: 12),
          _field(
            controller: _website,
            label: 'Website',
            hint: 'https://example.com',
            enabled: !locked,
            keyboardType: TextInputType.url,
            validator: _validateWebsite,
            autofillHints: const [AutofillHints.url],
          ),
          const SizedBox(height: 12),
          _field(
            controller: _supportEmail,
            label: 'Support email',
            enabled: !locked,
            keyboardType: TextInputType.emailAddress,
            validator: _validateEmail,
            autofillHints: const [AutofillHints.email],
          ),
          const SizedBox(height: 12),
          _field(
            controller: _supportPhone,
            label: 'Support phone',
            enabled: !locked,
            keyboardType: TextInputType.phone,
            validator: (value) => _digits(value).length >= 10
                ? null
                : 'Enter a valid support phone number.',
            autofillHints: const [AutofillHints.telephoneNumber],
          ),
          const SizedBox(height: 28),
          _StageActions(
            busy: _controller.isWorking,
            primaryLabel: locked ? 'Continue' : 'Save and continue',
            onPrimary: locked ? () => _controller.goToStep(1) : _saveBusiness,
          ),
        ],
      ),
    );
  }

  Widget _buildMessagingStage() {
    final samples = _sampleMessages();
    return Column(
      key: const Key('messaging-plan-stage'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const _StageHeading(
          eyebrow: 'STEP 2 OF 3',
          title: 'Choose what you will send',
          description:
              'Select every account-notification category you expect to use. We create compliant examples for the carrier review.',
        ),
        const SizedBox(height: 24),
        ..._useCases.entries.map(
          (entry) => Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: _UseCaseTile(
              title: entry.key,
              selected: entry.value,
              onChanged: _controller.isWorking
                  ? null
                  : (value) => setState(() => _useCases[entry.key] = value),
            ),
          ),
        ),
        if (!_useCases.containsValue(true)) ...[
          const SizedBox(height: 2),
          Text(
            'Select at least one message type.',
            key: const Key('use-case-error'),
            style: TextStyle(
              color: Theme.of(context).colorScheme.error,
              fontSize: 12,
            ),
          ),
        ],
        const SizedBox(height: 20),
        _SectionLabel('Carrier message previews'),
        const SizedBox(height: 10),
        ...samples.map(
          (sample) => Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: _MessagePreview(message: sample),
          ),
        ),
        const SizedBox(height: 18),
        const _InfoCallout(
          icon: Icons.verified_user_outlined,
          title: 'Consent remains required',
          message:
              'Only text tenants who voluntarily opted in. Every message identifies your facility and includes STOP and HELP instructions.',
        ),
        const SizedBox(height: 28),
        _StageActions(
          busy: _controller.isWorking,
          primaryLabel: 'Continue to review',
          onBack: () => _controller.goToStep(0),
          onPrimary: () {
            if (!_useCases.containsValue(true)) {
              setState(() {});
              return;
            }
            _controller.saveMessagingPlanLocally();
          },
        ),
      ],
    );
  }

  Widget _buildReviewStage() {
    return Form(
      key: _reviewFormKey,
      child: Column(
        key: const Key('review-stage'),
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const _StageHeading(
            eyebrow: 'STEP 3 OF 3',
            title: 'Review and submit',
            description:
                'We will reserve a dedicated local number and send your registration to the carriers.',
          ),
          const SizedBox(height: 24),
          _ReviewSection(
            title: 'Business',
            rows: {
              'Legal name': _legalName.text.trim(),
              'Type': _businessType,
              'Address':
                  '${_address1.text.trim()}, ${_city.text.trim()}, ${_state.text.trim()} ${_postal.text.trim()}',
            },
            onEdit: () => _controller.goToStep(0),
          ),
          const SizedBox(height: 14),
          _ReviewSection(
            title: 'Messaging plan',
            rows: {
              'Use cases': _selectedUseCases().join(', '),
              'Review time': 'Typically 10–15 business days',
            },
            onEdit: () => _controller.goToStep(1),
          ),
          const SizedBox(height: 20),
          _field(
            key: const Key('area-code'),
            controller: _areaCode,
            label: 'Preferred area code (optional)',
            hint: '512',
            keyboardType: TextInputType.number,
            validator: (value) {
              final digits = _digits(value);
              return digits.isEmpty || digits.length == 3
                  ? null
                  : 'Enter a 3-digit area code.';
            },
          ),
          const SizedBox(height: 16),
          CheckboxListTile(
            key: const Key('consent-confirmation'),
            value: _consent,
            contentPadding: EdgeInsets.zero,
            controlAffinity: ListTileControlAffinity.leading,
            onChanged: _controller.isWorking
                ? null
                : (value) => setState(() => _consent = value ?? false),
            title: const Text(
              'I confirm tenants voluntarily opt in before receiving account notifications, and consent is not required to rent.',
            ),
            subtitle: !_consent
                ? const Text('Required before registration can be submitted.')
                : null,
          ),
          const SizedBox(height: 10),
          const _InfoCallout(
            icon: Icons.schedule_outlined,
            title: 'What happens next',
            message:
                'Your number is reserved immediately. Texting stays disabled until carrier approval and a final SFC platform review are both complete.',
          ),
          const SizedBox(height: 28),
          _StageActions(
            busy: _controller.isWorking,
            primaryLabel: 'Reserve number & submit',
            onBack: () => _controller.goToStep(1),
            onPrimary: _submit,
          ),
        ],
      ),
    );
  }

  Widget _buildStatusDashboard() {
    final snapshot = _controller.snapshot!;
    final status = snapshot.status;
    final rejected = status == TextingRegistrationStatus.rejected;
    final carrierApproved = status == TextingRegistrationStatus.approved;
    final superAdmin =
        widget.isSuperAdminOverride ?? SuperAdminService.isSuperAdmin();

    final title = snapshot.isLive
        ? 'Texting is live'
        : rejected
            ? 'Registration needs attention'
            : carrierApproved
                ? 'Carrier approved'
                : 'Registration under review';
    final description = snapshot.isLive
        ? 'This facility can now send compliant account notifications from its dedicated number.'
        : rejected
            ? 'The carrier could not approve the registration as submitted.'
            : carrierApproved
                ? 'Carrier registration is complete. SFC platform approval is the final step.'
                : 'No action is needed right now. Carrier review typically takes 10–15 business days.';

    return Column(
      key: Key('status-${status.name}'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Card(
          margin: EdgeInsets.zero,
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _StatusIcon(
                  rejected: rejected,
                  live: snapshot.isLive,
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: Theme.of(context)
                            .textTheme
                            .headlineSmall
                            ?.copyWith(fontWeight: FontWeight.w700),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        description,
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                              color: Theme.of(context)
                                  .colorScheme
                                  .onSurfaceVariant,
                              height: 1.45,
                            ),
                      ),
                      if (snapshot.phoneNumber?.isNotEmpty == true) ...[
                        const SizedBox(height: 14),
                        SelectableText(
                          snapshot.phoneNumber!,
                          style: Theme.of(context)
                              .textTheme
                              .titleLarge
                              ?.copyWith(fontWeight: FontWeight.w700),
                        ),
                        Text(
                          'Dedicated facility number',
                          style:
                              Theme.of(context).textTheme.bodySmall?.copyWith(
                                    color: Theme.of(context)
                                        .colorScheme
                                        .onSurfaceVariant,
                                  ),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 18),
        LayoutBuilder(
          builder: (context, constraints) {
            final progress = _ApprovalProgress(snapshot: snapshot);
            final details = _RegistrationDetails(snapshot: snapshot);
            if (constraints.maxWidth < 760) {
              return Column(
                children: [
                  progress,
                  const SizedBox(height: 18),
                  details,
                ],
              );
            }
            return Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(flex: 3, child: progress),
                const SizedBox(width: 18),
                Expanded(flex: 2, child: details),
              ],
            );
          },
        ),
        if (rejected) ...[
          const SizedBox(height: 18),
          _RejectionCard(
            reason: snapshot.rejectionReason ??
                snapshot.lastError ??
                'The carrier did not provide a detailed reason.',
            busy: _controller.isWorking,
            onReview: _confirmResetAfterRejection,
          ),
        ],
        if (superAdmin && carrierApproved) ...[
          const SizedBox(height: 18),
          _AdminApprovalCard(
            approved: snapshot.platformApproved,
            busy: _controller.isWorking,
            onChanged: _controller.setPlatformApproval,
          ),
        ],
        const SizedBox(height: 14),
        Align(
          alignment: Alignment.centerRight,
          child: TextButton.icon(
            onPressed:
                _controller.isWorking ? null : () => _controller.refresh(),
            icon: const Icon(Icons.refresh_rounded, size: 18),
            label: Text(
              snapshot.isUnderReview
                  ? 'Refresh status · checks automatically'
                  : 'Refresh status',
            ),
          ),
        ),
      ],
    );
  }

  Future<void> _saveBusiness() async {
    if (_businessFormKey.currentState?.validate() != true) return;
    await _controller.saveBusinessInfo({
      'legalBusinessName': _legalName.text.trim(),
      'dba': _emptyToNull(_dba.text),
      'businessType': _businessType,
      'ein': _digits(_ein.text),
      'addressLine1': _address1.text.trim(),
      'city': _city.text.trim(),
      'state': _state.text.trim().toUpperCase(),
      'postalCode': _postal.text.trim(),
      'country': 'US',
      'website': _website.text.trim(),
      'supportEmail': _supportEmail.text.trim(),
      'supportPhone': _supportPhone.text.trim(),
    });
  }

  Future<void> _submit() async {
    if (_reviewFormKey.currentState?.validate() != true) return;
    if (!_consent) {
      setState(() {});
      return;
    }
    await _controller.provisionAndSubmit(
      areaCode: _emptyToNull(_digits(_areaCode.text)),
      useCases: _selectedUseCases(),
      sampleMessages: _sampleMessages(),
    );
  }

  Future<void> _confirmResetAfterRejection() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Review registration details?'),
        content: const Text(
          'This resets the carrier brand and campaign submission so you can review the messaging plan before submitting again.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Reset and review'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      final success = await _controller.resetAfterRejection();
      if (success) {
        _hydratedFacilityId = null;
        final snapshot = _controller.snapshot;
        if (snapshot != null) _hydrate(snapshot);
      }
    }
  }

  TextFormField _field({
    Key? key,
    required TextEditingController controller,
    required String label,
    String? hint,
    bool enabled = true,
    TextInputType? keyboardType,
    TextCapitalization textCapitalization = TextCapitalization.none,
    String? Function(String?)? validator,
    List<String>? autofillHints,
  }) {
    return TextFormField(
      key: key,
      controller: controller,
      enabled: enabled && !_controller.isWorking,
      keyboardType: keyboardType,
      textCapitalization: textCapitalization,
      validator: validator,
      autofillHints: autofillHints,
      decoration: InputDecoration(labelText: label, hintText: hint),
    );
  }

  List<String> _selectedUseCases() {
    return _useCases.entries
        .where((entry) => entry.value)
        .map((entry) => entry.key)
        .toList(growable: false);
  }

  String _brandName() {
    if (_dba.text.trim().isNotEmpty) return _dba.text.trim();
    if (_legalName.text.trim().isNotEmpty) return _legalName.text.trim();
    return 'Your storage facility';
  }

  List<String> _sampleMessages() {
    final brand = _brandName();
    final templates = <String, String>{
      'Payment reminders':
          '$brand: Friendly reminder — your rent payment is due soon. Reply STOP to opt out, HELP for help.',
      'Past-due notices':
          '$brand: Your account is past due. Please make a payment to avoid late fees. Reply STOP to opt out, HELP for help.',
      'Gate and access updates':
          '$brand: Your access information has been updated. Contact the office for help. Reply STOP to opt out, HELP for help.',
      'Operational notices':
          '$brand: Important facility notice — office hours have changed this week. Reply STOP to opt out, HELP for help.',
    };
    return _selectedUseCases()
        .map((useCase) => templates[useCase]!)
        .toList(growable: false);
  }

  static String? Function(String?) _required(String message) {
    return (value) => value?.trim().isNotEmpty == true ? null : message;
  }

  static String? _validateEmail(String? value) {
    return RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(value?.trim() ?? '')
        ? null
        : 'Enter a valid email address.';
  }

  static String? _validateWebsite(String? value) {
    final raw = value?.trim() ?? '';
    final uri = Uri.tryParse(raw);
    return uri != null &&
            (uri.scheme == 'https' || uri.scheme == 'http') &&
            uri.host.contains('.')
        ? null
        : 'Enter a full website URL, including https://.';
  }

  static String _digits(String? value) =>
      (value ?? '').replaceAll(RegExp(r'\D'), '');

  static String? _emptyToNull(String? value) {
    final trimmed = value?.trim() ?? '';
    return trimmed.isEmpty ? null : trimmed;
  }
}

class _PageHeader extends StatelessWidget {
  final List<FacilityModel> facilities;
  final String selectedFacilityId;
  final bool enabled;
  final ValueChanged<String?> onSelected;

  const _PageHeader({
    required this.facilities,
    required this.selectedFacilityId,
    required this.enabled,
    required this.onSelected,
  });

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final title = Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Facility texting',
              style: Theme.of(context)
                  .textTheme
                  .headlineMedium
                  ?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 4),
            Text(
              'Set up and manage compliant SMS notifications.',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
            ),
          ],
        );
        final selector = SizedBox(
          width: min(340, constraints.maxWidth),
          child: DropdownButtonFormField<String>(
            key: ValueKey(selectedFacilityId),
            initialValue: selectedFacilityId,
            isExpanded: true,
            decoration: const InputDecoration(
              labelText: 'Facility',
              prefixIcon: Icon(Icons.business_outlined),
            ),
            items: [
              for (final facility in facilities)
                DropdownMenuItem(
                  value: facility.id,
                  child: Text(
                    facility.name,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
            ],
            onChanged: enabled ? onSelected : null,
          ),
        );
        if (constraints.maxWidth < 650) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [title, const SizedBox(height: 16), selector],
          );
        }
        return Row(
          children: [
            Expanded(child: title),
            const SizedBox(width: 24),
            selector,
          ],
        );
      },
    );
  }
}

class _StepRail extends StatelessWidget {
  final int currentStep;
  final ValueChanged<int>? onStepSelected;
  final bool horizontal;

  const _StepRail({
    required this.currentStep,
    required this.onStepSelected,
    required this.horizontal,
  });

  @override
  Widget build(BuildContext context) {
    final children = List.generate(3, (index) {
      final active = index == currentStep;
      final complete = index < currentStep;
      return InkWell(
        onTap: onStepSelected == null ? null : () => onStepSelected!(index),
        borderRadius: BorderRadius.circular(10),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 8),
          child: Row(
            children: [
              CircleAvatar(
                radius: 15,
                backgroundColor: active || complete
                    ? Theme.of(context).colorScheme.primary
                    : Theme.of(context).colorScheme.surfaceContainerHighest,
                foregroundColor: active || complete
                    ? Theme.of(context).colorScheme.onPrimary
                    : Theme.of(context).colorScheme.onSurfaceVariant,
                child: complete
                    ? const Icon(Icons.check_rounded, size: 17)
                    : Text('${index + 1}'),
              ),
              const SizedBox(width: 9),
              if (!horizontal || MediaQuery.sizeOf(context).width > 520)
                Expanded(
                  child: Text(
                    _TextingSetupScreenState._stepTitles[index],
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          fontWeight:
                              active ? FontWeight.w700 : FontWeight.w500,
                          color: active
                              ? Theme.of(context).colorScheme.primary
                              : Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                  ),
                ),
            ],
          ),
        ),
      );
    });
    if (horizontal) {
      return Card(
        margin: EdgeInsets.zero,
        child: Row(
          children: children
              .map((child) => Expanded(child: child))
              .toList(growable: false),
        ),
      );
    }
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: children
              .map((child) => SizedBox(height: 52, child: child))
              .toList(),
        ),
      ),
    );
  }
}

class _StageHeading extends StatelessWidget {
  final String eyebrow;
  final String title;
  final String description;

  const _StageHeading({
    required this.eyebrow,
    required this.title,
    required this.description,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          eyebrow,
          style: Theme.of(context).textTheme.labelMedium?.copyWith(
                color: Theme.of(context).colorScheme.primary,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.8,
              ),
        ),
        const SizedBox(height: 8),
        Text(
          title,
          style: Theme.of(context)
              .textTheme
              .headlineSmall
              ?.copyWith(fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 8),
        Text(
          description,
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
                height: 1.5,
              ),
        ),
      ],
    );
  }
}

class _StageActions extends StatelessWidget {
  final bool busy;
  final String primaryLabel;
  final VoidCallback onPrimary;
  final VoidCallback? onBack;

  const _StageActions({
    required this.busy,
    required this.primaryLabel,
    required this.onPrimary,
    this.onBack,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        if (onBack != null)
          TextButton.icon(
            onPressed: busy ? null : onBack,
            icon: const Icon(Icons.arrow_back_rounded, size: 18),
            label: const Text('Back'),
          ),
        const Spacer(),
        FilledButton.icon(
          key: const Key('primary-stage-action'),
          onPressed: busy ? null : onPrimary,
          icon: busy
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.arrow_forward_rounded, size: 18),
          label: Text(busy ? 'Working…' : primaryLabel),
        ),
      ],
    );
  }
}

class _InfoCallout extends StatelessWidget {
  final IconData icon;
  final String title;
  final String message;

  const _InfoCallout({
    required this.icon,
    required this.title,
    required this.message,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: cs.primary.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: cs.primary.withValues(alpha: 0.16)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: cs.primary, size: 21),
          const SizedBox(width: 11),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: Theme.of(context)
                      .textTheme
                      .titleSmall
                      ?.copyWith(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 3),
                Text(
                  message,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        height: 1.45,
                        color: cs.onSurfaceVariant,
                      ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _UseCaseTile extends StatelessWidget {
  final String title;
  final bool selected;
  final ValueChanged<bool>? onChanged;

  const _UseCaseTile({
    required this.title,
    required this.selected,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Material(
      color: selected ? cs.primary.withValues(alpha: 0.06) : cs.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(
          color:
              selected ? cs.primary.withValues(alpha: 0.4) : cs.outlineVariant,
        ),
      ),
      child: CheckboxListTile(
        value: selected,
        onChanged:
            onChanged == null ? null : (value) => onChanged!(value ?? false),
        title: Text(title),
        subtitle: Text(_useCaseDescription(title)),
        controlAffinity: ListTileControlAffinity.leading,
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
      ),
    );
  }

  static String _useCaseDescription(String title) {
    return switch (title) {
      'Payment reminders' => 'Upcoming rent and payment due reminders',
      'Past-due notices' => 'Delinquency and late-fee account notices',
      'Gate and access updates' => 'Access-code and gate availability updates',
      _ => 'Office hours, closures, and facility operations',
    };
  }
}

class _MessagePreview extends StatelessWidget {
  final String message;

  const _MessagePreview({required this.message});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            Icons.chat_bubble_outline_rounded,
            size: 19,
            color: Theme.of(context).colorScheme.primary,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              message,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    height: 1.5,
                  ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ReviewSection extends StatelessWidget {
  final String title;
  final Map<String, String> rows;
  final VoidCallback onEdit;

  const _ReviewSection({
    required this.title,
    required this.rows,
    required this.onEdit,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  title,
                  style: Theme.of(context)
                      .textTheme
                      .titleMedium
                      ?.copyWith(fontWeight: FontWeight.w700),
                ),
              ),
              TextButton(onPressed: onEdit, child: const Text('Edit')),
            ],
          ),
          ...rows.entries.map(
            (entry) => Padding(
              padding: const EdgeInsets.only(top: 9),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 95,
                    child: Text(
                      entry.key,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color:
                                Theme.of(context).colorScheme.onSurfaceVariant,
                          ),
                    ),
                  ),
                  Expanded(child: Text(entry.value)),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ApprovalProgress extends StatelessWidget {
  final TextingOnboardingSnapshot snapshot;

  const _ApprovalProgress({required this.snapshot});

  @override
  Widget build(BuildContext context) {
    final carrierDone = snapshot.status == TextingRegistrationStatus.approved;
    final rejected = snapshot.status == TextingRegistrationStatus.rejected;
    final steps = [
      (
        'Registration submitted',
        true,
        _formatDate(snapshot.submittedAt) ?? 'Complete',
      ),
      (
        'Carrier review',
        carrierDone,
        rejected
            ? 'Needs attention'
            : carrierDone
                ? 'Approved'
                : 'In progress',
      ),
      (
        'SFC platform approval',
        snapshot.platformApproved,
        snapshot.platformApproved
            ? 'Approved'
            : carrierDone
                ? 'Pending'
                : 'Waiting for carrier',
      ),
      (
        'Texting live',
        snapshot.isLive,
        snapshot.isLive ? 'Ready to send' : 'Not active yet',
      ),
    ];
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(22),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Approval progress',
              style: Theme.of(context)
                  .textTheme
                  .titleMedium
                  ?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 18),
            ...steps.asMap().entries.map((entry) {
              final index = entry.key;
              final step = entry.value;
              return _ProgressRow(
                title: step.$1,
                complete: step.$2,
                detail: step.$3,
                rejected: rejected && index == 1,
                showLine: index < steps.length - 1,
              );
            }),
          ],
        ),
      ),
    );
  }

  static String? _formatDate(DateTime? date) {
    if (date == null) return null;
    return DateFormat.yMMMd().format(date.toLocal());
  }
}

class _ProgressRow extends StatelessWidget {
  final String title;
  final bool complete;
  final String detail;
  final bool rejected;
  final bool showLine;

  const _ProgressRow({
    required this.title,
    required this.complete,
    required this.detail,
    required this.rejected,
    required this.showLine,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final color = rejected
        ? cs.error
        : complete
            ? AppTheme.success
            : cs.onSurfaceVariant;
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            width: 28,
            child: Column(
              children: [
                Icon(
                  rejected
                      ? Icons.error_rounded
                      : complete
                          ? Icons.check_circle_rounded
                          : Icons.radio_button_unchecked_rounded,
                  color: color,
                  size: 20,
                ),
                if (showLine)
                  Expanded(
                    child: Container(
                      width: 2,
                      margin: const EdgeInsets.symmetric(vertical: 3),
                      color: cs.outlineVariant,
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Padding(
              padding: EdgeInsets.only(bottom: showLine ? 20 : 0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: Theme.of(context)
                        .textTheme
                        .bodyMedium
                        ?.copyWith(fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    detail,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: color,
                        ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _RegistrationDetails extends StatelessWidget {
  final TextingOnboardingSnapshot snapshot;

  const _RegistrationDetails({required this.snapshot});

  @override
  Widget build(BuildContext context) {
    final business = snapshot.businessDetails;
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(22),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Registration details',
              style: Theme.of(context)
                  .textTheme
                  .titleMedium
                  ?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 16),
            _DetailRow(
              label: 'Business',
              value: business?.legalBusinessName ?? 'Saved carrier profile',
            ),
            _DetailRow(
              label: 'Use cases',
              value: snapshot.useCases.isEmpty
                  ? 'Account notifications'
                  : snapshot.useCases.join(', '),
            ),
            _DetailRow(
              label: 'Carrier status',
              value: snapshot.status.name.toUpperCase(),
            ),
            if (snapshot.approvedAt != null)
              _DetailRow(
                label: 'Approved',
                value:
                    DateFormat.yMMMd().format(snapshot.approvedAt!.toLocal()),
              ),
          ],
        ),
      ),
    );
  }
}

class _DetailRow extends StatelessWidget {
  final String label;
  final String value;

  const _DetailRow({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
          ),
          const SizedBox(height: 3),
          Text(value, style: Theme.of(context).textTheme.bodyMedium),
        ],
      ),
    );
  }
}

class _RejectionCard extends StatelessWidget {
  final String reason;
  final bool busy;
  final VoidCallback onReview;

  const _RejectionCard({
    required this.reason,
    required this.busy,
    required this.onReview,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Card(
      margin: EdgeInsets.zero,
      color: cs.errorContainer.withValues(alpha: 0.35),
      child: Padding(
        padding: const EdgeInsets.all(22),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Carrier feedback',
              style: Theme.of(context)
                  .textTheme
                  .titleMedium
                  ?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 8),
            SelectableText(reason),
            const SizedBox(height: 8),
            Text(
              'Review the details before resetting. Resetting removes the current brand and campaign submission.',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: cs.onSurfaceVariant,
                  ),
            ),
            const SizedBox(height: 16),
            OutlinedButton.icon(
              onPressed: busy ? null : onReview,
              icon: const Icon(Icons.edit_note_rounded),
              label: const Text('Review and resubmit'),
            ),
          ],
        ),
      ),
    );
  }
}

class _AdminApprovalCard extends StatelessWidget {
  final bool approved;
  final bool busy;
  final ValueChanged<bool> onChanged;

  const _AdminApprovalCard({
    required this.approved,
    required this.busy,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(22),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              Icons.admin_panel_settings_outlined,
              color: Theme.of(context).colorScheme.primary,
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'SFC platform review',
                    style: Theme.of(context)
                        .textTheme
                        .titleMedium
                        ?.copyWith(fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 5),
                  Text(
                    approved
                        ? 'This facility is approved to send SMS.'
                        : 'Carrier approval is complete. Verify the facility before enabling SMS.',
                  ),
                  const SizedBox(height: 14),
                  Wrap(
                    spacing: 10,
                    children: [
                      FilledButton(
                        onPressed:
                            busy || approved ? null : () => onChanged(true),
                        child: const Text('Approve texting'),
                      ),
                      if (approved)
                        OutlinedButton(
                          onPressed: busy ? null : () => onChanged(false),
                          child: const Text('Revoke approval'),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _StatusIcon extends StatelessWidget {
  final bool rejected;
  final bool live;

  const _StatusIcon({required this.rejected, required this.live});

  @override
  Widget build(BuildContext context) {
    final color = rejected
        ? Theme.of(context).colorScheme.error
        : live
            ? AppTheme.success
            : Theme.of(context).colorScheme.primary;
    return Container(
      width: 48,
      height: 48,
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Icon(
        rejected
            ? Icons.error_outline_rounded
            : live
                ? Icons.check_circle_outline_rounded
                : Icons.schedule_send_outlined,
        color: color,
      ),
    );
  }
}

class _ErrorBanner extends StatelessWidget {
  final String message;
  final VoidCallback onDismiss;

  const _ErrorBanner({required this.message, required this.onDismiss});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Material(
      color: cs.errorContainer.withValues(alpha: 0.45),
      borderRadius: BorderRadius.circular(10),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 10, 8, 10),
        child: Row(
          children: [
            Icon(Icons.error_outline_rounded, color: cs.error),
            const SizedBox(width: 10),
            Expanded(child: Text(message)),
            IconButton(
              tooltip: 'Dismiss',
              onPressed: onDismiss,
              icon: const Icon(Icons.close_rounded),
            ),
          ],
        ),
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  final String text;

  const _SectionLabel(this.text);

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: Theme.of(context)
          .textTheme
          .titleMedium
          ?.copyWith(fontWeight: FontWeight.w700),
    );
  }
}

class _SetupSkeleton extends StatelessWidget {
  const _SetupSkeleton();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          CircularProgressIndicator(),
          SizedBox(height: 14),
          Text('Loading texting setup…'),
        ],
      ),
    );
  }
}

class _NoFacilities extends StatelessWidget {
  const _NoFacilities();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Padding(
        padding: EdgeInsets.all(24),
        child: _InfoCallout(
          icon: Icons.business_outlined,
          title: 'Create a facility first',
          message:
              'Texting is configured per facility. Create a facility, then return here to continue.',
        ),
      ),
    );
  }
}

class _LoadFailure extends StatelessWidget {
  final VoidCallback onRetry;

  const _LoadFailure({required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.cloud_off_outlined, size: 42),
          const SizedBox(height: 12),
          const Text('Could not load your facilities.'),
          const SizedBox(height: 12),
          OutlinedButton(onPressed: onRetry, child: const Text('Try again')),
        ],
      ),
    );
  }
}
