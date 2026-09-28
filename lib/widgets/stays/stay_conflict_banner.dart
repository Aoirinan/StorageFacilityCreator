import 'package:flutter/material.dart';

import 'package:sfcapp/models/stays/stay.dart';
import 'package:sfcapp/services/stays/stays_calendar_grid.dart';
import 'package:sfcapp/services/stays/stays_display.dart';
import 'package:sfcapp/theme/app_theme.dart';

/// "Double booking" for a listing (or the whole facility): each stay the
/// engine marked `conflict`, the nights it lost, and who holds them. Nothing
/// when there are none. [onOpen] opens a stay (e.g. its peek sheet).
class StayConflictBanner extends StatelessWidget {
  const StayConflictBanner({super.key, required this.conflicts, this.showListing = false, this.onOpen});

  final List<StayConflictSummary> conflicts;

  /// Name the listing in each line (the facility-wide banner).
  final bool showListing;
  final void Function(Stay stay)? onOpen;

  static String lineFor(StayConflictSummary c, {bool showListing = false}) {
    final nights = describeNights(c.nights);
    final where = showListing && c.stay.listingName.isNotEmpty ? '${c.stay.listingName}: ' : '';
    final holders = c.holders.map((s) => s.guestLabel).toSet().join(' and ');
    final holderText = holders.isEmpty ? 'another booking' : holders;
    return '$where${c.stay.guestLabel} and $holderText both have ${nights.isEmpty ? 'the same nights' : nights}.';
  }

  @override
  Widget build(BuildContext context) {
    if (conflicts.isEmpty) return const SizedBox.shrink();
    final open = onOpen;
    return Container(
      key: const Key('stay-conflict-banner'),
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppTheme.error.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppTheme.error),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.warning_rounded, color: AppTheme.error),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  conflicts.length == 1 ? 'Double booking' : '${conflicts.length} double bookings',
                  style: const TextStyle(fontWeight: FontWeight.w700, color: AppTheme.error),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          for (final c in conflicts)
            InkWell(
              onTap: open == null ? null : () => open(c.stay),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: Text(
                  '${lineFor(c, showListing: showListing)}${c.acknowledged ? ' (seen)' : ''}',
                ),
              ),
            ),
          const SizedBox(height: 4),
          Text(
            'The earlier booking keeps the nights. Cancel one of them on the site it was booked on; '
            'Stays clears this within about 30 minutes of the channel dropping it.',
            style: TextStyle(fontSize: 13, color: Theme.of(context).colorScheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}
