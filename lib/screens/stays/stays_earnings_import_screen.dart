import 'package:flutter/material.dart';

import 'package:sfcapp/widgets/stays/stays_empty_state.dart';

/// The Airbnb CSV import: upload, server preview, map listings, commit.
///
/// A WP0 stub: the class name and constructor are final; WP3 replaces
/// the body. Stays is behind the shortTermRentals flag, so nobody reaches
/// this page until then.
class StaysEarningsImportScreen extends StatelessWidget {
  const StaysEarningsImportScreen({super.key, required this.facilityId});

  final String facilityId;

  @override
  Widget build(BuildContext context) {
    return const StaysEmptyState(
      icon: Icons.construction_outlined,
      title: 'Stays Earnings Import',
      subtitle: 'This part of Stays is not built yet.',
    );
  }
}
