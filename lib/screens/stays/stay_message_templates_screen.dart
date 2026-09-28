import 'package:flutter/material.dart';

import 'package:sfcapp/widgets/stays/stays_empty_state.dart';

/// The copy-first message template editor (owner/manager).
///
/// A WP0 stub: the class name and constructor are final; WP5 replaces
/// the body. Stays is behind the shortTermRentals flag, so nobody reaches
/// this page until then.
class StayMessageTemplatesScreen extends StatelessWidget {
  const StayMessageTemplatesScreen({super.key, required this.facilityId});

  final String facilityId;

  @override
  Widget build(BuildContext context) {
    return const StaysEmptyState(
      icon: Icons.construction_outlined,
      title: 'Stay Message Templates',
      subtitle: 'This part of Stays is not built yet.',
    );
  }
}
