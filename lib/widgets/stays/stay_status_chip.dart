import 'package:flutter/material.dart';

import 'package:sfcapp/models/stays/stay_enums.dart';
import 'package:sfcapp/theme/app_theme.dart';

/// A stay's status as a chip: a 1px border with a 10% fill. Unknown
/// statuses render neutrally.
class StayStatusChip extends StatelessWidget {
  const StayStatusChip({super.key, required this.status, this.arrivalState, this.dense = false});

  final StayStatus status;

  /// When given (and the stay holds its nights), shows the arrival state instead.
  final StayArrivalState? arrivalState;
  final bool dense;

  static (String, Color) labelAndColor(StayStatus status, StayArrivalState? arrival, ColorScheme scheme) {
    switch (status) {
      case StayStatus.conflict:
        return ('Double booked', AppTheme.error);
      case StayStatus.cancelled:
        return ('Cancelled', scheme.onSurfaceVariant);
      case StayStatus.removedFromFeed:
        return ('Removed from channel', AppTheme.warning);
      case StayStatus.unknown:
        return ('Unknown', scheme.onSurfaceVariant);
      case StayStatus.confirmed:
        break;
    }
    switch (arrival) {
      case StayArrivalState.checkedIn:
        return ('Checked in', AppTheme.success);
      case StayArrivalState.checkedOut:
        return ('Checked out', scheme.onSurfaceVariant);
      case StayArrivalState.noShow:
        return ('No-show', AppTheme.warning);
      case StayArrivalState.upcoming:
      case StayArrivalState.unknown:
      case null:
        return ('Confirmed', AppTheme.info);
    }
  }

  @override
  Widget build(BuildContext context) {
    final (label, color) = labelAndColor(status, arrivalState, Theme.of(context).colorScheme);
    return Container(
      padding: EdgeInsets.symmetric(horizontal: dense ? 6 : 8, vertical: dense ? 1 : 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color, width: 1),
      ),
      child: Text(
        label,
        style: TextStyle(fontSize: dense ? 11 : 12, fontWeight: FontWeight.w600, color: color),
      ),
    );
  }
}
