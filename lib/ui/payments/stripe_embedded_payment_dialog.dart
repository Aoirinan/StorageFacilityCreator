import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'stripe_embedded_payment_dialog_web.dart'
    if (dart.library.io) 'stripe_embedded_payment_dialog_stub.dart' as impl;

import '../../services/stripe_payments_service.dart';

/// Result of the embedded Stripe dialog
class StripeDialogResult {
  final bool succeeded;
  final String? error;
  /// When mode is 'setup' and succeeded, the Stripe payment method ID (pm_xxx) to attach on the backend
  final String? paymentMethodId;
  /// When mode is 'setup' and succeeded, the SetupIntent ID (seti_xxx) for verification
  final String? setupIntentId;
  /// When mode is 'payment' and succeeded, the PaymentIntent ID (pi_xxx)
  final String? paymentIntentId;

  const StripeDialogResult({
    required this.succeeded,
    this.error,
    this.paymentMethodId,
    this.setupIntentId,
    this.paymentIntentId,
  });
}

/// Shows Stripe Payment Element in an iframe dialog (Flutter Web)
/// If [publishableKeyFromBackend] is provided, it is used (must match the SetupIntent/PaymentIntent).
/// For Connect: pass [stripeAccount] (connected account id) so Stripe.js uses the same account as the SetupIntent (avoids 401).
Future<StripeDialogResult?> showStripeEmbeddedDialog({
  required BuildContext context,
  required String clientSecret,
  required String mode, // 'setup' | 'payment'
  required String returnUrl,
  String? publishableKeyFromBackend,
  String? stripeAccount,
}) async {
  return impl.showStripeEmbeddedDialogImpl(
    context: context,
    clientSecret: clientSecret,
    mode: mode,
    returnUrl: returnUrl,
    publishableKeyFromBackend: publishableKeyFromBackend,
    stripeAccount: stripeAccount,
  );
}
