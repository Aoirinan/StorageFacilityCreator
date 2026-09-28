import 'package:flutter/material.dart';

import 'package:sfcapp/widgets/stays/stays_empty_state.dart';

/// Listings grouped (Airbnbs, house, RV park), read-only for staff.
///
/// A WP0 stub: the class name and constructor are final; WP5 replaces
/// the body. Stays is behind the shortTermRentals flag, so nobody reaches
/// this page until then.
class StaysListingsTab extends StatelessWidget {
  const StaysListingsTab({super.key, required this.facilityId});

  final String facilityId;

  @override
  Widget build(BuildContext context) {
    return const StaysEmptyState(
      icon: Icons.construction_outlined,
      title: 'Stays Listings',
      subtitle: 'This part of Stays is not built yet.',
    );
  }
}
