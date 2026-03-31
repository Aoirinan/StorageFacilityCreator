// Stub for non-web platforms

import 'package:flutter/foundation.dart';

class StripeConfirmResult {
  final bool succeeded;
  final String? error;

  const StripeConfirmResult({required this.succeeded, this.error});
}

class StripeWebBridge {
  static Future<void> initialize(String publishableKey) async {
    if (kDebugMode) {
      print('StripeWebBridge: Not available on this platform');
    }
  }

  static Future<void> mountSetupElement(String containerId, String clientSecret) async {
    throw UnsupportedError('Stripe Payment Element is only supported on Flutter Web');
  }

  static Future<void> mountPaymentElement(String containerId, String clientSecret) async {
    throw UnsupportedError('Stripe Payment Element is only supported on Flutter Web');
  }

  static Future<void> unmount() async {}

  static Future<StripeConfirmResult> confirmSetup(String returnUrl) async {
    return const StripeConfirmResult(succeeded: false, error: 'Not supported on this platform');
  }

  static Future<StripeConfirmResult> confirmPayment(String returnUrl) async {
    return const StripeConfirmResult(succeeded: false, error: 'Not supported on this platform');
  }

  static bool get isInitialized => false;
}
