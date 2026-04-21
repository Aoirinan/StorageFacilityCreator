import 'package:flutter/material.dart';
import 'package:sfcapp/screens/facility_map_builder_v2_screen.dart';

/// Opens the facility map editor (Map V2 builder only).
class UnitsMapEntryScreen extends StatelessWidget {
  final String facilityId;

  const UnitsMapEntryScreen({
    super.key,
    required this.facilityId,
  });

  @override
  Widget build(BuildContext context) {
    return FacilityMapBuilderV2Screen(facilityId: facilityId);
  }
}
