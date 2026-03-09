import 'package:flutter/material.dart';

Widget buildPaymentElementHost({
  required String containerId,
  required double height,
}) {
  return SizedBox(
    height: height,
    child: const Center(
      child: Text('Stripe Payment Element is only available on web'),
    ),
  );
}
