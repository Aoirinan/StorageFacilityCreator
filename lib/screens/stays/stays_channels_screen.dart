import 'package:flutter/material.dart';

import 'package:sfcapp/widgets/stays/stays_empty_state.dart';

/// Calendar feeds, export links and the sync log (owner/manager).
///
/// A WP0 stub: the class name and constructor are final; WP5 replaces
/// the body. Stays is behind the shortTermRentals flag, so nobody reaches
/// this page until then.
class StaysChannelsScreen extends StatelessWidget {
  const StaysChannelsScreen({super.key, required this.facilityId, this.listingId});

  final String facilityId;
  final String? listingId;

  @override
  Widget build(BuildContext context) {
    return const StaysEmptyState(
      icon: Icons.construction_outlined,
      title: 'Stays Channels',
      subtitle: 'This part of Stays is not built yet.',
    );
  }
}
