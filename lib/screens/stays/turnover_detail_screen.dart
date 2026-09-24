import 'package:flutter/material.dart';

import 'package:sfcapp/models/stays/stay_task.dart';
import 'package:sfcapp/widgets/stays/stays_empty_state.dart';

/// One turnover: a phone-first checklist, supplies, "Issue found" with photos, Start and Done.
///
/// A WP0 stub: the class name and constructor are final; WP4 replaces
/// the body. Stays is behind the shortTermRentals flag, so nobody reaches
/// this page until then.
class TurnoverDetailScreen extends StatelessWidget {
  const TurnoverDetailScreen({super.key, required this.facilityId, required this.task});

  final String facilityId;
  final StayTask task;

  @override
  Widget build(BuildContext context) {
    return const StaysEmptyState(
      icon: Icons.construction_outlined,
      title: 'Turnover Detail',
      subtitle: 'This part of Stays is not built yet.',
    );
  }
}
