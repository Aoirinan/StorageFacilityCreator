import 'package:flutter/material.dart';

import 'package:sfcapp/widgets/stays/stays_empty_state.dart';

/// Stays settings: time zone, employee switches, default times, payment methods, park rules.
///
/// A WP0 stub: the class name and constructor are final; WP5 replaces
/// the body. Stays is behind the shortTermRentals flag, so nobody reaches
/// this page until then.
class StaysSettingsScreen extends StatelessWidget {
  const StaysSettingsScreen({super.key, required this.facilityId});

  final String facilityId;

  @override
  Widget build(BuildContext context) {
    return const StaysEmptyState(
      icon: Icons.construction_outlined,
      title: 'Stays Settings',
      subtitle: 'This part of Stays is not built yet.',
    );
  }
}
