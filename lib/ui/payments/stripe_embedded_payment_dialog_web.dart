import 'dart:async';
import 'dart:html' as html;
import 'package:flutter/material.dart';

import 'stripe_embedded_payment_dialog.dart';
import '../../services/stripe_payments_service.dart';
import '../../widgets/stripe_payment_element_host.dart';

Future<StripeDialogResult?> showStripeEmbeddedDialogImpl({
  required BuildContext context,
  required String clientSecret,
  required String mode,
  required String returnUrl,
  String? publishableKeyFromBackend,
  String? stripeAccount,
}) async {
  String? publishableKey = publishableKeyFromBackend?.trim().isNotEmpty == true
      ? publishableKeyFromBackend
      : await StripePaymentsService.getPublishableKey();
  if (publishableKey == null || publishableKey.isEmpty) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Stripe is not configured')),
      );
    }
    return null;
  }

  return showDialog<StripeDialogResult>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => _StripeEmbeddedDialog(
      clientSecret: clientSecret,
      publishableKey: publishableKey!,
      mode: mode,
      returnUrl: returnUrl,
      stripeAccount: stripeAccount,
    ),
  );
}

class _StripeEmbeddedDialog extends StatefulWidget {
  final String clientSecret;
  final String publishableKey;
  final String mode;
  final String returnUrl;
  final String? stripeAccount;

  const _StripeEmbeddedDialog({
    required this.clientSecret,
    required this.publishableKey,
    required this.mode,
    required this.returnUrl,
    this.stripeAccount,
  });

  @override
  State<_StripeEmbeddedDialog> createState() => _StripeEmbeddedDialogState();
}

class _StripeEmbeddedDialogState extends State<_StripeEmbeddedDialog> {
  StreamSubscription<html.MessageEvent>? _sub;

  @override
  void initState() {
    super.initState();
    _sub = html.window.onMessage.listen((e) {
      final d = e.data;
      if (d is! Map) return;
      final type = d['type'];
      if (type == 'STRIPE_EMBED_READY') {
        _sendConfigTo(e.source);
      } else if (type == 'STRIPE_EMBED_RESULT') {
        final succeeded = d['succeeded'] == true;
        final error = d['error'] as String?;
        final paymentMethodId = d['paymentMethodId'] as String?;
        final setupIntentId = d['setupIntentId'] as String?;
        if (mounted) {
          Navigator.of(context).pop(StripeDialogResult(
            succeeded: succeeded,
            error: error,
            paymentMethodId: paymentMethodId,
            setupIntentId: setupIntentId,
          ));
        }
      }
    });
    Future.microtask(() => _sendConfig());
  }

  void _sendConfig() {
    for (final f in html.document.querySelectorAll('iframe[src*="stripe_embedded"]')) {
      (f as html.IFrameElement).contentWindow?.postMessage({
        'type': 'STRIPE_EMBED_INIT',
        'publishableKey': widget.publishableKey,
        'clientSecret': widget.clientSecret,
        'mode': widget.mode,
        'returnUrl': widget.returnUrl,
        if (widget.stripeAccount != null) 'stripeAccount': widget.stripeAccount,
      }, '*');
    }
  }

  void _sendConfigTo(dynamic target) {
    if (target == null) return;
    try {
      target.postMessage({
        'type': 'STRIPE_EMBED_INIT',
        'publishableKey': widget.publishableKey,
        'clientSecret': widget.clientSecret,
        'mode': widget.mode,
        'returnUrl': widget.returnUrl,
        if (widget.stripeAccount != null) 'stripeAccount': widget.stripeAccount,
      }, '*');
    } catch (_) {}
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.mode == 'setup' ? 'Add payment method' : 'Pay now'),
      content: SizedBox(
        width: 400,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: const StripePaymentElementHost(
            containerId: 'stripe-embed',
            height: 220,
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
      ],
    );
  }
}
