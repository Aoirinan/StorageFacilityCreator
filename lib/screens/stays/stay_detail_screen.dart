import 'package:flutter/material.dart';

import 'package:sfcapp/models/stays/stay.dart';
import 'package:sfcapp/widgets/stays/stays_empty_state.dart';

/// One stay: status, dates, guest, access, money, turnover, messages and timeline.
///
/// A WP0 stub: the class name and constructor are final; WP4 replaces
/// the body. Stays is behind the shortTermRentals flag, so nobody reaches
/// this page until then.
class StayDetailScreen extends StatelessWidget {
  const StayDetailScreen({super.key, required this.facilityId, required this.stay});

  final String facilityId;
  final Stay stay;

  @override
  Widget build(BuildContext context) {
    return const StaysEmptyState(
      icon: Icons.construction_outlined,
      title: 'Stay Detail',
      subtitle: 'This part of Stays is not built yet.',
    );
  }
}
