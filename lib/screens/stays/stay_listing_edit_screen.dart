import 'package:flutter/material.dart';

import 'package:sfcapp/widgets/stays/stays_empty_state.dart';

/// Create or edit a listing. [listingId] null creates one.
///
/// A WP0 stub: the class name and constructor are final; WP5 replaces
/// the body. Stays is behind the shortTermRentals flag, so nobody reaches
/// this page until then.
class StayListingEditScreen extends StatelessWidget {
  const StayListingEditScreen({super.key, required this.facilityId, this.listingId});

  final String facilityId;
  final String? listingId;

  @override
  Widget build(BuildContext context) {
    return const StaysEmptyState(
      icon: Icons.construction_outlined,
      title: 'Stay Listing Edit',
      subtitle: 'This part of Stays is not built yet.',
    );
  }
}
