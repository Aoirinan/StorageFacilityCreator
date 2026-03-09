import 'package:flutter/material.dart';
import 'stripe_embedded_payment_dialog.dart';

Future<StripeDialogResult?> showStripeEmbeddedDialogImpl({
  required BuildContext context,
  required String clientSecret,
  required String mode,
  required String returnUrl,
  String? publishableKeyFromBackend,
  String? stripeAccount,
}) async {
  if (context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Stripe payments are only available on web')),
    );
  }
  return null;
}
