import 'package:flutter/material.dart';

import 'package:sfcapp/widgets/stays/stays_empty_state.dart';

/// The setup wizard (spec §1.1 K); confirms the time zone first and calls staysSetControls last.
///
/// A WP0 stub: the class name and constructor are final; WP5 replaces
/// the body. Stays is behind the shortTermRentals flag, so nobody reaches
/// this page until then.
class StaysSetupWizardScreen extends StatelessWidget {
  const StaysSetupWizardScreen({super.key, required this.facilityId});

  final String facilityId;

  @override
  Widget build(BuildContext context) {
    return const StaysEmptyState(
      icon: Icons.construction_outlined,
      title: 'Stays Setup Wizard',
      subtitle: 'This part of Stays is not built yet.',
    );
  }
}
