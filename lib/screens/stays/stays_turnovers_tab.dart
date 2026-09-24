import 'package:flutter/material.dart';

import 'package:sfcapp/widgets/stays/stays_empty_state.dart';

/// Turnovers grouped by day, with a "Mine" filter for employees.
///
/// A WP0 stub: the class name and constructor are final; WP4 replaces
/// the body. Stays is behind the shortTermRentals flag, so nobody reaches
/// this page until then.
class StaysTurnoversTab extends StatelessWidget {
  const StaysTurnoversTab({super.key, required this.facilityId});

  final String facilityId;

  @override
  Widget build(BuildContext context) {
    return const StaysEmptyState(
      icon: Icons.construction_outlined,
      title: 'Stays Turnovers',
      subtitle: 'This part of Stays is not built yet.',
    );
  }
}
