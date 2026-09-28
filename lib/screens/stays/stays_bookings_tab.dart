import 'package:flutter/material.dart';

import 'package:sfcapp/widgets/stays/stays_empty_state.dart';

/// Bookings as a table or card list, with filters and CSV download.
///
/// A WP0 stub: the class name and constructor are final; WP4 replaces
/// the body. Stays is behind the shortTermRentals flag, so nobody reaches
/// this page until then.
class StaysBookingsTab extends StatelessWidget {
  const StaysBookingsTab({super.key, required this.facilityId});

  final String facilityId;

  @override
  Widget build(BuildContext context) {
    return const StaysEmptyState(
      icon: Icons.construction_outlined,
      title: 'Stays Bookings',
      subtitle: 'This part of Stays is not built yet.',
    );
  }
}
