import 'package:flutter/material.dart';

import 'package:sfcapp/models/stays/stay_enums.dart';

/// Where a booking came from (Airbnb, VRBO, direct, walk-up, …): the same
/// colours as the tape chart's bars. Unknown sources render neutrally.
class StaySourceBadge extends StatelessWidget {
  const StaySourceBadge({super.key, required this.source, this.kind, this.dense = false});

  final StaySource source;

  /// Owner and maintenance blocks are labelled as blocks whatever their source.
  final StayKind? kind;
  final bool dense;

  static const Color airbnbColor = Color(0xFFFF5A5F);
  static const Color vrboColor = Color(0xFF1C4695);
  static const Color bookingColor = Color(0xFF003580);
  static const Color hipcampColor = Color(0xFF2E7D32);
  static const Color directColor = Color(0xFF7C3AED);
  static const Color phoneColor = Color(0xFF0E7490);
  static const Color walkUpColor = Color(0xFFB45309);
  static const Color blockColor = Color(0xFF6B7280);

  static (String, Color) labelAndColor(StaySource source, StayKind? kind) {
    if (kind == StayKind.ownerBlock) return ('Owner block', blockColor);
    if (kind == StayKind.maintenanceBlock) return ('Maintenance', blockColor);
    return switch (source) {
      StaySource.airbnb => ('Airbnb', airbnbColor),
      StaySource.vrbo => ('VRBO', vrboColor),
      StaySource.booking => ('Booking.com', bookingColor),
      StaySource.hipcamp => ('Hipcamp', hipcampColor),
      StaySource.otherChannel => ('Channel', blockColor),
      StaySource.direct => ('Direct', directColor),
      StaySource.phone => ('Phone', phoneColor),
      StaySource.walkUp => ('Walk-up', walkUpColor),
      StaySource.owner => ('Owner', blockColor),
      StaySource.unknown => ('Other', blockColor),
    };
  }

  @override
  Widget build(BuildContext context) {
    final (label, color) = labelAndColor(source, kind);
    return Container(
      padding: EdgeInsets.symmetric(horizontal: dense ? 6 : 8, vertical: dense ? 1 : 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        label,
        style: TextStyle(fontSize: dense ? 11 : 12, fontWeight: FontWeight.w600, color: color),
      ),
    );
  }
}
