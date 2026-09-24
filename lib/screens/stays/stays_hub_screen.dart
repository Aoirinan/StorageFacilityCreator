import 'package:flutter/material.dart';

import 'package:sfcapp/widgets/stays/stays_empty_state.dart';

/// The Stays hub: Today, Calendar, Bookings, Turnovers, Earnings and Listings tabs, with ?tab= kept in sync.
///
/// A WP0 stub: the class name and constructor are final; WP4 replaces
/// the body. Stays is behind the shortTermRentals flag, so nobody reaches
/// this page until then.
class StaysHubScreen extends StatelessWidget {
  const StaysHubScreen({super.key, required this.facilityId, this.initialTab = 'today'});

  final String facilityId;
  final String initialTab;

  @override
  Widget build(BuildContext context) {
    return const StaysEmptyState(
      icon: Icons.construction_outlined,
      title: 'Stays Hub',
      subtitle: 'This part of Stays is not built yet.',
    );
  }
}
