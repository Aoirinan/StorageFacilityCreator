import 'dart:html' as html;
import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/material.dart';

// Conditional import for web-only platform view
import 'stripe_payment_element_host_stub.dart'
    if (dart.library.html) 'stripe_payment_element_host_web.dart' as impl;

/// Hosts the Stripe Payment Element (Flutter Web only)
/// On other platforms, shows a placeholder
class StripePaymentElementHost extends StatelessWidget {
  final String containerId;
  final double height;

  const StripePaymentElementHost({
    super.key,
    required this.containerId,
    this.height = 200,
  });

  @override
  Widget build(BuildContext context) {
    return impl.buildPaymentElementHost(
      containerId: containerId,
      height: height,
    );
  }
}
