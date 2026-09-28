import 'package:flutter/material.dart';

import 'package:sfcapp/models/stays/stay.dart';
import 'package:sfcapp/models/stays/stay_enums.dart';
import 'package:sfcapp/widgets/stays/stays_empty_state.dart';

/// Create or edit a booking or block. [stay] null creates; the other fields prefill a new one.
///
/// A WP0 stub: the class name and constructor are final; WP4 replaces
/// the body. Stays is behind the shortTermRentals flag, so nobody reaches
/// this page until then.
class StayEditScreen extends StatelessWidget {
  const StayEditScreen({super.key, required this.facilityId, this.stay, this.listingId, this.checkIn, this.checkOut, this.kind});

  final String facilityId;
  final Stay? stay;
  final String? listingId;
  final String? checkIn;
  final String? checkOut;
  final StayKind? kind;

  @override
  Widget build(BuildContext context) {
    return const StaysEmptyState(
      icon: Icons.construction_outlined,
      title: 'Stay Edit',
      subtitle: 'This part of Stays is not built yet.',
    );
  }
}
