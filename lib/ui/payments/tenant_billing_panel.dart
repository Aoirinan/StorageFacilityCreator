import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:cloud_functions/cloud_functions.dart';

import '../../models/stripe_connect_status_model.dart';
import '../../models/tenant_billing_model.dart';
import '../../models/tenant_stripe_payment_model.dart';
import '../../models/saved_payment_method_model.dart';
import '../../models/payment_model.dart';
import '../../services/stripe_connect_service.dart';
import '../../services/stripe_payments_service.dart';
import '../../services/stripe_service.dart';
import '../../theme/app_theme.dart';
import '../../utils/error_message_helper.dart';
import '../../utils/print_util.dart';
import '../../providers/tenant_provider.dart';
import '../../providers/payment_provider.dart';
import '../../router/app_route.dart';
import 'stripe_embedded_payment_dialog.dart';

/// Panel for tenant Stripe billing: Add Card, AutoPay, One-Time Payment, History
class TenantBillingPanel extends ConsumerStatefulWidget {
  final String facilityId;
  final String tenantId;
  final String tenantName;
  /// Default payment method ID from tenant.stripe (Connect account) for "Pay with card on file"
  final String? defaultPaymentMethodId;

  const TenantBillingPanel({
    super.key,
    required this.facilityId,
    required this.tenantId,
    required this.tenantName,
    this.defaultPaymentMethodId,
  });

  @override
  ConsumerState<TenantBillingPanel> createState() => _TenantBillingPanelState();
}

class _TenantBillingPanelState extends ConsumerState<TenantBillingPanel> {
  bool _isLoading = false;
  String? _error;
  StripeConnectStatusResult? _connectStatus;
  bool _statusLoading = true;

  @override
  void initState() {
    super.initState();
    _loadConnectStatus();
  }

  Future<void> _loadConnectStatus() async {
    setState(() => _statusLoading = true);
    try {
      final result = await StripeConnectService.refreshStatus(widget.facilityId);
      if (mounted) setState(() {
        _connectStatus = result;
        _statusLoading = false;
      });
    } catch (e) {
      if (mounted) setState(() {
        _statusLoading = false;
        _connectStatus = null;
      });
    }
  }

  Future<void> _addCard() async {
    if (!kIsWeb) return;
    if (_connectStatus != null && !_connectStatus!.isEnabled) return;
    setState(() {
      _isLoading = true;
      _error = null;
    });
    try {
      final data = await StripeService.createTenantSetupIntent(
        facilityId: widget.facilityId,
        tenantId: widget.tenantId,
      );
      final clientSecret = data['clientSecret'] as String?;
      final publishableKey = data['publishableKey'] as String?;
      final connectedAccountId = data['connectedAccountId'] as String?;
      if (clientSecret == null) throw Exception('No client secret returned');
      if (!mounted) return;
      final baseUrl = Uri.base.origin;
      final paymentsUrl = '${AppRoute.payments}?tab=autopay&tenantId=${widget.tenantId}&facilityId=${widget.facilityId}&cardAdded=1';
      final result = await showStripeEmbeddedDialog(
        context: context,
        clientSecret: clientSecret,
        mode: 'setup',
        returnUrl: '$baseUrl/#$paymentsUrl',
        publishableKeyFromBackend: publishableKey,
        stripeAccount: connectedAccountId,
      );
      if (!mounted) return;
      if (result != null && result.succeeded) {
        bool attachSucceeded = false;
        if (result.paymentMethodId != null && result.paymentMethodId!.isNotEmpty) {
          try {
            await StripeService.attachTenantPaymentMethod(
              facilityId: widget.facilityId,
              tenantId: widget.tenantId,
              paymentMethodId: result.paymentMethodId!,
              setupIntentId: result.setupIntentId,
            );
            attachSucceeded = true;
            if (mounted) ref.invalidate(facilityTenantsProvider(widget.facilityId));
          } catch (attachError) {
            if (mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text('Card was saved in Stripe but could not link to this tenant. ${ErrorMessageHelper.getUserFriendlyMessage(attachError)}'),
                  backgroundColor: AppTheme.warning,
                  duration: const Duration(seconds: 5),
                ),
              );
            }
          }
        }
        if (mounted && attachSucceeded) {
          context.go('$paymentsUrl');
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Card added successfully.'), backgroundColor: AppTheme.success),
          );
        } else if (mounted && result.paymentMethodId == null) {
          // Edge case: succeeded but no paymentMethodId (e.g. redirect before postMessage).
          // Navigate to payments page - if Stripe appended redirect params to URL, the
          // payment list handler will attach the card when it loads.
          context.go('$paymentsUrl');
        }
      } else if (result != null && result.error != null) {
        setState(() => _error = result.error);
      }
    } catch (e) {
      if (mounted) {
        final message = ErrorMessageHelper.getUserFriendlyMessage(e);
        final isInternalOrUnavailable = e is FirebaseFunctionsException &&
            (e.code == 'internal' || e.code == 'unavailable');
        setState(() => _error = isInternalOrUnavailable
            ? 'Unable to load the card form. Please refresh the page and try again. If you use a browser extension that blocks scripts (e.g. ad blockers), try disabling it for this site.'
            : message);
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _toggleAutopay(bool enable) async {
    setState(() {
      _isLoading = true;
      _error = null;
    });
    try {
      await StripePaymentsService.toggleAutopay(
        facilityId: widget.facilityId,
        tenantId: widget.tenantId,
        enable: enable,
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(enable ? 'AutoPay enabled' : 'AutoPay disabled')),
        );
      }
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _payWithCardOnFile() async {
    final amount = await showDialog<double>(
      context: context,
      builder: (ctx) => _AmountDialog(tenantName: widget.tenantName),
    );
    if (amount == null || amount < 0.50) return;
    final pmId = widget.defaultPaymentMethodId;
    if (pmId == null || pmId.isEmpty) return;
    setState(() {
      _isLoading = true;
      _error = null;
    });
    try {
      final result = await StripeService.chargeTenantOffSession(
        facilityId: widget.facilityId,
        tenantId: widget.tenantId,
        paymentMethodId: pmId,
        amount: amount,
        description: 'One-time payment',
      );
      if (mounted) {
        ref.invalidate(facilityTenantsProvider(widget.facilityId));
        final paymentIntentId = result['paymentIntentId'] as String?;
        final recordingWarning = result['recordingWarning'] as String?;
        if (recordingWarning != null && recordingWarning.isNotEmpty) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(recordingWarning),
              duration: const Duration(seconds: 10),
              backgroundColor: AppTheme.warning,
            ),
          );
        }
        await showDialog<void>(
          context: context,
          builder: (ctx) => _PaymentReceiptDialog(
            tenantName: widget.tenantName,
            amount: amount,
            transactionId: paymentIntentId,
          ),
        );
      }
    } catch (e) {
      if (mounted) setState(() => _error = ErrorMessageHelper.getUserFriendlyMessage(e));
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _recordManualPayment() async {
    final result = await showDialog<({double amount, PaymentMethod method, String? notes})>(
      context: context,
      builder: (ctx) => _ManualPaymentDialog(tenantName: widget.tenantName),
    );
    if (result == null || result.amount < 0.01) return;
    setState(() {
      _isLoading = true;
      _error = null;
    });
    try {
      await ref.read(paymentOperationsProvider.notifier).recordManualPayment(
        facilityId: widget.facilityId,
        tenantId: widget.tenantId,
        amount: result.amount,
        method: result.method,
        notes: result.notes?.isEmpty == true ? null : result.notes,
      );
      if (mounted) {
        ref.invalidate(facilityTenantsProvider(widget.facilityId));
        ref.invalidate(paymentListProvider(widget.facilityId));
        ref.invalidate(paymentStatsProvider(widget.facilityId));
        await showDialog<void>(
          context: context,
          builder: (ctx) => _PaymentReceiptDialog(
            tenantName: widget.tenantName,
            amount: result.amount,
            transactionId: null,
          ),
        );
      }
    } catch (e) {
      if (mounted) setState(() => _error = ErrorMessageHelper.getUserFriendlyMessage(e));
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _payWithNewCard() async {
    if (!kIsWeb) return;
    final amount = await showDialog<double>(
      context: context,
      builder: (ctx) => _AmountDialog(tenantName: widget.tenantName),
    );
    if (amount == null || amount < 0.50) return;
    final amountCents = (amount * 100).round();
    setState(() {
      _isLoading = true;
      _error = null;
    });
    try {
      final data = await StripeService.createOneTimePaymentIntentOnConnectedAccount(
        facilityId: widget.facilityId,
        tenantId: widget.tenantId,
        amountCents: amountCents,
      );
      final clientSecret = data['clientSecret'] as String?;
      final publishableKey = data['publishableKey'] as String?;
      final connectedAccountId = data['connectedAccountId'] as String?;
      if (clientSecret == null) throw Exception('No client secret returned');
      if (!mounted) return;
      final baseUrl = Uri.base.origin;
      final result = await showStripeEmbeddedDialog(
        context: context,
        clientSecret: clientSecret,
        mode: 'payment',
        returnUrl: '$baseUrl/#/payments',
        publishableKeyFromBackend: publishableKey,
        stripeAccount: connectedAccountId,
      );
      if (!mounted) return;
      if (result != null && result.succeeded) {
        ref.invalidate(facilityTenantsProvider(widget.facilityId));
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Payment successful. It will appear in Payment History shortly.'),
            backgroundColor: AppTheme.success,
            duration: Duration(seconds: 4),
          ),
        );
      } else if (result != null && result.error != null) {
        setState(() => _error = result.error);
      }
    } catch (e) {
      if (mounted) setState(() => _error = ErrorMessageHelper.getUserFriendlyMessage(e));
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  String _ctaLabel() {
    if (_connectStatus == null) return 'Connect Stripe';
    switch (_connectStatus!.state) {
      case StripeConnectState.disconnected:
        return 'Connect Stripe';
      case StripeConnectState.onboardingIncomplete:
        return 'Finish Stripe Onboarding';
      case StripeConnectState.actionRequired:
        return 'Resolve Stripe Requirements';
      case StripeConnectState.enabled:
        return 'Connect Stripe';
    }
  }

  Future<void> _onCtaPressed() async {
    try {
      final url = await StripeConnectService.connectOrFinishOnboarding(widget.facilityId);
      if (!mounted) return;
      await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
    } catch (e) {
      if (mounted) {
        setState(() => _error = ErrorMessageHelper.getUserFriendlyMessage(e));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: StripePaymentsService.watchTenantBilling(
        facilityId: widget.facilityId,
        tenantId: widget.tenantId,
      ),
      builder: (context, billingSnapshot) {
        final billing = billingSnapshot.hasData && billingSnapshot.data!.exists
            ? TenantBillingModel.fromFirestore(billingSnapshot.data!)
            : null;
        final showPaymentForm = _connectStatus != null && _connectStatus!.isEnabled;
        final hasCardOnFile = (billing != null && billing.hasCard) ||
            (widget.defaultPaymentMethodId != null && widget.defaultPaymentMethodId!.isNotEmpty);
        return Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(Icons.credit_card, color: Theme.of(context).colorScheme.primary),
                    const SizedBox(width: 8),
                    Text('Payment methods', style: Theme.of(context).textTheme.titleMedium),
                  ],
                ),
                if (_statusLoading) ...[
                  const SizedBox(height: 12),
                  const Center(child: Padding(padding: EdgeInsets.all(16), child: CircularProgressIndicator())),
                ] else if (_connectStatus != null && !_connectStatus!.isEnabled) ...[
                  const SizedBox(height: 12),
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.surfaceContainerHighest.withOpacity(0.5),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          "Payments aren't enabled yet for this facility.",
                          style: Theme.of(context).textTheme.bodyMedium,
                        ),
                        const SizedBox(height: 12),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            ElevatedButton.icon(
                              onPressed: _onCtaPressed,
                              icon: const Icon(Icons.link, size: 18),
                              label: Text(_ctaLabel()),
                            ),
                            OutlinedButton.icon(
                              onPressed: _loadConnectStatus,
                              icon: const Icon(Icons.refresh, size: 18),
                              label: const Text('Refresh Status'),
                            ),
                            OutlinedButton.icon(
                              onPressed: _recordManualPayment,
                              icon: const Icon(Icons.payments_outlined, size: 18),
                              label: const Text('Record cash/check'),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
                if (_error != null) ...[
                  const SizedBox(height: 12),
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: AppTheme.error.withOpacity(0.1),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Row(
                      children: [
                        Icon(Icons.error_outline, color: AppTheme.error, size: 20),
                        const SizedBox(width: 8),
                        Expanded(child: Text(_error!, style: TextStyle(color: AppTheme.error))),
                      ],
                    ),
                  ),
                ],
                if (showPaymentForm && billing?.lastFailureMessage != null && billing!.lastPaymentStatus == 'failed') ...[
                  const SizedBox(height: 8),
                  Text(
                    'Last payment failed: ${billing.lastFailureMessage}',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(color: AppTheme.error),
                  ),
                ],
                if (showPaymentForm) ...[
                  const SizedBox(height: 12),
                  if (_isLoading)
                    const Center(child: Padding(padding: EdgeInsets.all(16), child: CircularProgressIndicator())),
                  if (!_isLoading) ...[
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        if (kIsWeb)
                          ElevatedButton.icon(
                            onPressed: _addCard,
                            icon: const Icon(Icons.add),
                            label: Text(hasCardOnFile ? 'Update card' : 'Add card'),
                          ),
                        if (kIsWeb && hasCardOnFile)
                          OutlinedButton.icon(
                            onPressed: _payWithCardOnFile,
                            icon: const Icon(Icons.credit_card),
                            label: const Text('Pay with card on file'),
                          ),
                        if (kIsWeb)
                          OutlinedButton.icon(
                            onPressed: _payWithNewCard,
                            icon: const Icon(Icons.payment),
                            label: const Text('Pay with new card'),
                          ),
                        OutlinedButton.icon(
                          onPressed: _recordManualPayment,
                          icon: const Icon(Icons.payments_outlined),
                          label: const Text('Record cash/check'),
                        ),
                      ],
                    ),
                    if (hasCardOnFile) ...[
                      const SizedBox(height: 16),
                      Row(
                        children: [
                          Text('AutoPay', style: Theme.of(context).textTheme.bodyMedium),
                          const SizedBox(width: 12),
                          Switch(
                            value: billing?.autopayEnabled ?? false,
                            onChanged: (v) => _toggleAutopay(v),
                          ),
                          if (billing?.autopayEnabled ?? false)
                            Text('On', style: Theme.of(context).textTheme.bodySmall?.copyWith(color: AppTheme.success)),
                        ],
                      ),
                    ],
                  ],
                ],
                const SizedBox(height: 16),
                Text('Payment history', style: Theme.of(context).textTheme.titleSmall),
                const SizedBox(height: 8),
                StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
                  stream: StripePaymentsService.watchTenantPayments(
                    facilityId: widget.facilityId,
                    tenantId: widget.tenantId,
                  ),
                  builder: (context, paymentsSnapshot) {
                    if (!paymentsSnapshot.hasData || paymentsSnapshot.data!.docs.isEmpty) {
                      return Text(
                        'No payments yet',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(color: AppTheme.textTertiary),
                      );
                    }
                    return Column(
                      children: paymentsSnapshot.data!.docs.take(10).map((doc) {
                        final p = TenantStripePaymentModel.fromFirestore(doc);
                        return ListTile(
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          leading: Icon(
                            p.isSucceeded ? Icons.check_circle : p.isFailed ? Icons.error : Icons.schedule,
                            color: p.isSucceeded ? AppTheme.success : p.isFailed ? AppTheme.error : null,
                            size: 20,
                          ),
                          title: Text('${p.formattedAmount} · ${p.status}'),
                          subtitle: p.failureMessage != null ? Text(p.failureMessage!, style: TextStyle(color: AppTheme.error, fontSize: 12)) : null,
                        );
                      }).toList(),
                    );
                  },
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// Receipt dialog shown after a successful one-time payment (card on file).
class _PaymentReceiptDialog extends StatelessWidget {
  final String tenantName;
  final double amount;
  final String? transactionId;

  const _PaymentReceiptDialog({
    required this.tenantName,
    required this.amount,
    this.transactionId,
  });

  @override
  Widget build(BuildContext context) {
    final date = DateTime.now();
    return AlertDialog(
      title: Row(
        children: [
          Icon(Icons.receipt_long, color: AppTheme.success),
          const SizedBox(width: 8),
          const Text('Payment receipt'),
        ],
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Payment received', style: Theme.of(context).textTheme.titleMedium?.copyWith(color: AppTheme.success)),
          const SizedBox(height: 12),
          _ReceiptRow(label: 'Tenant', value: tenantName),
          _ReceiptRow(label: 'Amount', value: '\$${amount.toStringAsFixed(2)}'),
          _ReceiptRow(label: 'Date', value: _formatDate(date)),
          if (transactionId != null && transactionId!.isNotEmpty)
            _ReceiptRow(label: 'Transaction ID', value: transactionId!),
          const SizedBox(height: 8),
          Text(
            'This payment has been saved and appears in Payment History below.',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(color: AppTheme.textTertiary),
          ),
        ],
      ),
      actions: [
        if (kIsWeb)
          OutlinedButton.icon(
            onPressed: () {
              printWindow();
            },
            icon: const Icon(Icons.print, size: 18),
            label: const Text('Print receipt'),
          ),
        ElevatedButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Done'),
        ),
      ],
    );
  }

  String _formatDate(DateTime d) {
    return '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')} '
        '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
  }
}

class _ReceiptRow extends StatelessWidget {
  final String label;
  final String value;

  const _ReceiptRow({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(width: 100, child: Text(label, style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: AppTheme.textTertiary))),
          Expanded(child: Text(value, style: const TextStyle(fontWeight: FontWeight.w500))),
        ],
      ),
    );
  }
}

class _ManualPaymentDialog extends StatefulWidget {
  final String tenantName;

  const _ManualPaymentDialog({required this.tenantName});

  @override
  State<_ManualPaymentDialog> createState() => _ManualPaymentDialogState();
}

class _ManualPaymentDialogState extends State<_ManualPaymentDialog> {
  final _amountController = TextEditingController();
  final _notesController = TextEditingController();
  PaymentMethod _method = PaymentMethod.cash;

  static const _manualMethods = [
    PaymentMethod.cash,
    PaymentMethod.check,
    PaymentMethod.bankTransfer,
  ];

  @override
  void dispose() {
    _amountController.dispose();
    _notesController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Record payment (cash, check, etc.)'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _amountController,
            decoration: const InputDecoration(
              labelText: 'Amount (\$)',
              prefixText: '\$ ',
              border: OutlineInputBorder(),
            ),
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            autofocus: true,
          ),
          const SizedBox(height: 16),
          DropdownButtonFormField<PaymentMethod>(
            value: _method,
            decoration: const InputDecoration(
              labelText: 'Payment method',
              border: OutlineInputBorder(),
            ),
            items: _manualMethods
                .map((m) => DropdownMenuItem(value: m, child: Text(m.displayName)))
                .toList(),
            onChanged: (v) => setState(() => _method = v ?? PaymentMethod.cash),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _notesController,
            decoration: const InputDecoration(
              labelText: 'Notes (optional)',
              border: OutlineInputBorder(),
            ),
            maxLines: 2,
          ),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        ElevatedButton(
          onPressed: () {
            final amount = double.tryParse(_amountController.text);
            if (amount != null && amount >= 0.01) {
              Navigator.pop(context, (amount: amount, method: _method, notes: _notesController.text.trim().isEmpty ? null : _notesController.text.trim()));
            }
          },
          child: const Text('Record payment'),
        ),
      ],
    );
  }
}

class _AmountDialog extends StatefulWidget {
  final String tenantName;

  const _AmountDialog({required this.tenantName});

  @override
  State<_AmountDialog> createState() => _AmountDialogState();
}

class _AmountDialogState extends State<_AmountDialog> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('One-time payment'),
      content: TextField(
        controller: _controller,
        decoration: const InputDecoration(
          labelText: 'Amount (\$)',
          prefixText: '\$ ',
          border: OutlineInputBorder(),
        ),
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        autofocus: true,
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        ElevatedButton(
          onPressed: () {
            final v = double.tryParse(_controller.text);
            Navigator.pop(context, v);
          },
          child: const Text('Continue'),
        ),
      ],
    );
  }
}
