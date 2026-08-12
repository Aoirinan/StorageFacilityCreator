import 'package:flutter/material.dart';

import '../../models/cancellation_retention_model.dart';
import '../../models/facility_model.dart';
import '../../services/cancellation_retention_service.dart';
import '../../theme/app_theme.dart';
import '../../utils/error_message_helper.dart';

/// Multi-step Facebook-style cancel flow for platform ($75) or website ($25).
class CancellationRetentionWizard extends StatefulWidget {
  final FacilityModel facility;
  final String? initialPlanType;
  final bool allowPlanPicker;
  final VoidCallback? onCompleted;

  const CancellationRetentionWizard({
    super.key,
    required this.facility,
    this.initialPlanType,
    this.allowPlanPicker = false,
    this.onCompleted,
  });

  static Future<bool?> show(
    BuildContext context, {
    required FacilityModel facility,
    String? initialPlanType,
    bool allowPlanPicker = false,
  }) {
    return showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => Dialog.fullscreen(
        child: CancellationRetentionWizard(
          facility: facility,
          initialPlanType: initialPlanType,
          allowPlanPicker: allowPlanPicker,
          onCompleted: () => Navigator.of(ctx).pop(true),
        ),
      ),
    );
  }

  @override
  State<CancellationRetentionWizard> createState() =>
      _CancellationRetentionWizardState();
}

class _CancellationRetentionWizardState
    extends State<CancellationRetentionWizard> {
  int _step = 0;
  bool _loading = true;
  bool _busy = false;
  String? _error;
  CancellationRetentionConfig? _config;

  String? _planType;
  String? _primaryReason;
  String? _detailReason;
  String? _eventId;
  List<String> _lossCopy = const [];
  List<CancellationPromo> _promos = const [];
  String? _selectedPromoId;

  bool get _platformCancellable =>
      widget.facility.stripePlatformSubscriptionId != null &&
      !(widget.facility.platformSubscriptionCancelAtPeriodEnd);
  bool get _websiteCancellable =>
      widget.facility.hasActiveStripeWebsiteSubscription &&
      !widget.facility.websiteSubscriptionCancelAtPeriodEnd;

  @override
  void initState() {
    super.initState();
    _planType = widget.initialPlanType;
    if (!widget.allowPlanPicker && _planType == null) {
      _planType = _platformCancellable
          ? 'platform'
          : (_websiteCancellable ? 'website' : null);
    }
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final config = await CancellationRetentionService.getConfig();
      if (!mounted) return;
      setState(() {
        _config = config;
        _loading = false;
        if (widget.allowPlanPicker && _planType == null) {
          _step = 0;
        } else {
          _step = widget.allowPlanPicker ? 1 : 0;
        }
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = ErrorMessageHelper.getUserFriendlyMessage(e);
      });
    }
  }

  List<CancellationReasonOption> get _detailOptions {
    final config = _config;
    final primary = _primaryReason;
    if (config == null || primary == null) return const [];
    return config.detailReasonsByPrimary[primary] ?? const [];
  }

  Future<void> _submitIntentAndContinue() async {
    final planType = _planType;
    final primary = _primaryReason;
    final detail = _detailReason;
    if (planType == null || primary == null || detail == null) return;

    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final result = await CancellationRetentionService.submitIntent(
        facilityId: widget.facility.id,
        planType: planType,
        primaryReason: primary,
        detailReason: detail,
      );
      if (!mounted) return;
      setState(() {
        _eventId = result.eventId;
        _lossCopy = result.lossCopy;
        _promos = result.promos;
        _selectedPromoId =
            result.promos.isNotEmpty ? result.promos.first.id : null;
        _busy = false;
        _step = widget.allowPlanPicker ? 3 : 2; // loss copy step
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = ErrorMessageHelper.getUserFriendlyMessage(e);
      });
    }
  }

  Future<void> _acceptOffer() async {
    final eventId = _eventId;
    final promoId = _selectedPromoId;
    if (eventId == null || promoId == null) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final message = await CancellationRetentionService.acceptOffer(
        eventId: eventId,
        promoId: promoId,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(message), backgroundColor: AppTheme.success),
      );
      widget.onCompleted?.call();
      if (mounted && Navigator.of(context).canPop()) {
        Navigator.of(context).pop(true);
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = ErrorMessageHelper.getUserFriendlyMessage(e);
      });
    }
  }

  Future<void> _confirmCancel() async {
    final eventId = _eventId;
    if (eventId == null) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final message =
          await CancellationRetentionService.confirmCancel(eventId: eventId);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(message), backgroundColor: AppTheme.success),
      );
      widget.onCompleted?.call();
      if (mounted && Navigator.of(context).canPop()) {
        Navigator.of(context).pop(true);
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = ErrorMessageHelper.getUserFriendlyMessage(e);
      });
    }
  }

  void _goNextFromReasons() {
    if (_primaryReason == null || _detailReason == null) {
      setState(() => _error = 'Please choose both answers to continue.');
      return;
    }
    _submitIntentAndContinue();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return Scaffold(
      appBar: AppBar(
        backgroundColor: cs.surface,
        foregroundColor: cs.onSurface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 1,
        title: Text(
          'Before you cancel',
          style: theme.textTheme.titleLarge
              ?.copyWith(fontWeight: FontWeight.w600, letterSpacing: -0.2),
        ),
        leading: IconButton(
          icon: const Icon(Icons.close),
          onPressed: _busy ? null : () => Navigator.of(context).pop(false),
        ),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(1),
          child: Divider(height: 1, thickness: 1, color: cs.outlineVariant),
        ),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _config == null
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(_error ?? 'Could not load cancellation options.'),
                        const SizedBox(height: 12),
                        FilledButton(
                            onPressed: _load, child: const Text('Retry')),
                      ],
                    ),
                  ),
                )
              : Align(
                  alignment: Alignment.topCenter,
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 640),
                    child: ListView(
                      padding: const EdgeInsets.all(20),
                      children: [
                        Text(
                          widget.facility.name,
                          style: theme.textTheme.titleMedium?.copyWith(
                            color: AppTheme.textSecondary,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          _stepTitle(),
                          style: theme.textTheme.headlineSmall?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 16),
                        if (_error != null) ...[
                          Text(_error!,
                              style: const TextStyle(color: AppTheme.error)),
                          const SizedBox(height: 12),
                        ],
                        _buildStepBody(),
                        const SizedBox(height: 24),
                        _buildNavButtons(),
                      ],
                    ),
                  ),
                ),
    );
  }

  String _stepTitle() {
    if (widget.allowPlanPicker && _step == 0) {
      return 'Which plan do you want to cancel?';
    }
    final reasonStep = widget.allowPlanPicker ? 1 : 0;
    final lossStep = widget.allowPlanPicker ? 3 : 2;
    final offerStep = widget.allowPlanPicker ? 4 : 3;
    final confirmStep = widget.allowPlanPicker ? 5 : 4;
    if (_step == reasonStep) return 'Help us understand why';
    if (_step == reasonStep + 1) return 'A bit more detail';
    if (_step == lossStep) return 'What you will lose';
    if (_step == offerStep) return 'Wait — special offer to stay';
    if (_step == confirmStep) return 'Confirm cancellation';
    return 'Cancel subscription';
  }

  Widget _buildStepBody() {
    if (widget.allowPlanPicker && _step == 0) {
      return Column(
        children: [
          if (_platformCancellable)
            _planTile(
              value: 'platform',
              title: 'Facility software — \$75/month',
              subtitle: 'Tenant, unit, payment, and operations tools',
            ),
          if (_websiteCancellable)
            _planTile(
              value: 'website',
              title: 'Public website — \$25/month',
              subtitle: 'Marketing site and online rentals for this facility',
            ),
          if (!_platformCancellable && !_websiteCancellable)
            const Text('No cancellable subscriptions found for this facility.'),
        ],
      );
    }

    final reasonStep = widget.allowPlanPicker ? 1 : 0;
    if (_step == reasonStep) {
      return DropdownButtonFormField<String>(
        value: _primaryReason,
        decoration: const InputDecoration(
          labelText: 'Main reason',
          border: OutlineInputBorder(),
        ),
        items: _config!.primaryReasons
            .map((r) => DropdownMenuItem(value: r.id, child: Text(r.label)))
            .toList(),
        onChanged: (v) => setState(() {
          _primaryReason = v;
          _detailReason = null;
          _error = null;
        }),
      );
    }

    if (_step == reasonStep + 1) {
      return DropdownButtonFormField<String>(
        value: _detailReason,
        decoration: const InputDecoration(
          labelText: 'More specifically',
          border: OutlineInputBorder(),
        ),
        items: _detailOptions
            .map((r) => DropdownMenuItem(value: r.id, child: Text(r.label)))
            .toList(),
        onChanged: (v) => setState(() {
          _detailReason = v;
          _error = null;
        }),
      );
    }

    final lossStep = widget.allowPlanPicker ? 3 : 2;
    if (_step == lossStep) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: _lossCopy
            .map(
              (line) => Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Icon(Icons.warning_amber_rounded,
                        color: AppTheme.warning, size: 20),
                    const SizedBox(width: 8),
                    Expanded(child: Text(line)),
                  ],
                ),
              ),
            )
            .toList(),
      );
    }

    final offerStep = widget.allowPlanPicker ? 4 : 3;
    if (_step == offerStep) {
      if (_promos.isEmpty) {
        return const Text(
          'No stay offers are available right now. You can still continue to cancel at period end.',
        );
      }
      return Column(
        children: _promos.map((promo) {
          final selected = _selectedPromoId == promo.id;
          return Card(
            margin: const EdgeInsets.only(bottom: 10),
            child: RadioListTile<String>(
              value: promo.id,
              groupValue: _selectedPromoId,
              onChanged: (v) => setState(() => _selectedPromoId = v),
              title: Text(promo.title,
                  style: TextStyle(
                      fontWeight:
                          selected ? FontWeight.w700 : FontWeight.w500)),
              subtitle: Text(promo.body),
            ),
          );
        }).toList(),
      );
    }

    // Confirm
    final planLabel =
        _planType == 'website' ? 'website add-on (\$25/mo)' : 'facility plan (\$75/mo)';
    return Text(
      'Cancel the $planLabel for "${widget.facility.name}"?\n\n'
      'You keep access until the end of the current billing period. '
      'This cannot be undone from this screen (you can resubscribe later).',
    );
  }

  Widget _planTile({
    required String value,
    required String title,
    required String subtitle,
  }) {
    return Card(
      child: RadioListTile<String>(
        value: value,
        groupValue: _planType,
        onChanged: (v) => setState(() => _planType = v),
        title: Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
        subtitle: Text(subtitle),
      ),
    );
  }

  Widget _buildNavButtons() {
    final offerStep = widget.allowPlanPicker ? 4 : 3;
    final confirmStep = widget.allowPlanPicker ? 5 : 4;
    final lossStep = widget.allowPlanPicker ? 3 : 2;
    final detailStep = widget.allowPlanPicker ? 2 : 1;

    return Row(
      children: [
        if (_step > 0)
          TextButton(
            onPressed: _busy
                ? null
                : () => setState(() {
                      _step -= 1;
                      _error = null;
                    }),
            child: const Text('Back'),
          ),
        const Spacer(),
        if (_step == offerStep && _promos.isNotEmpty) ...[
          OutlinedButton(
            onPressed: _busy
                ? null
                : () => setState(() {
                      _step = confirmStep;
                      _error = null;
                    }),
            child: const Text('No thanks, continue'),
          ),
          const SizedBox(width: 8),
          FilledButton(
            onPressed: _busy || _selectedPromoId == null ? null : _acceptOffer,
            child: Text(_busy ? 'Applying…' : 'Accept offer & stay'),
          ),
        ] else if (_step == confirmStep) ...[
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppTheme.error),
            onPressed: _busy ? null : _confirmCancel,
            child: Text(_busy ? 'Cancelling…' : 'Yes, cancel at period end'),
          ),
        ] else if (_step == lossStep) ...[
          FilledButton(
            onPressed: _busy
                ? null
                : () => setState(() {
                      _step = _promos.isEmpty ? confirmStep : offerStep;
                      _error = null;
                    }),
            child: const Text('Continue'),
          ),
        ] else if (_step == detailStep) ...[
          FilledButton(
            onPressed: _busy ? null : _goNextFromReasons,
            child: Text(_busy ? 'Saving…' : 'Continue'),
          ),
        ] else ...[
          FilledButton(
            onPressed: _busy
                ? null
                : () {
                    if (widget.allowPlanPicker && _step == 0 && _planType == null) {
                      setState(() =>
                          _error = 'Select a plan to cancel.');
                      return;
                    }
                    if (!widget.allowPlanPicker &&
                        _step == 0 &&
                        _primaryReason == null) {
                      setState(() =>
                          _error = 'Please choose a reason.');
                      return;
                    }
                    if (widget.allowPlanPicker &&
                        _step == 1 &&
                        _primaryReason == null) {
                      setState(() =>
                          _error = 'Please choose a reason.');
                      return;
                    }
                    setState(() {
                      _step += 1;
                      _error = null;
                    });
                  },
            child: const Text('Continue'),
          ),
        ],
      ],
    );
  }
}
