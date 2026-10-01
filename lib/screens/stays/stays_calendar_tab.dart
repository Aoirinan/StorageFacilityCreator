import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'package:sfcapp/models/permission_model.dart';
import 'package:sfcapp/models/stays/stay.dart';
import 'package:sfcapp/models/stays/stay_channel_blocks.dart';
import 'package:sfcapp/models/stays/stay_listing.dart';
import 'package:sfcapp/providers/stays_providers.dart';
import 'package:sfcapp/router/app_route.dart';
import 'package:sfcapp/services/stays/stays_calendar_grid.dart';
import 'package:sfcapp/services/stays/stays_display.dart';
import 'package:sfcapp/utils/local_date.dart';
import 'package:sfcapp/widgets/stays/quick_block_sheet.dart';
import 'package:sfcapp/widgets/stays/stay_conflict_banner.dart';
import 'package:sfcapp/widgets/stays/stay_month_calendar.dart';
import 'package:sfcapp/widgets/stays/stay_peek_sheet.dart';
import 'package:sfcapp/widgets/stays/stays_empty_state.dart';

/// The month calendar of one listing at a time: bookings, owner blocks,
/// channel blocks (soft), bookings removed from a channel, and double
/// bookings, with a banner for the listing's conflicts. Tap a night for what
/// is on it; owners and managers can block and unblock dates.
class StaysCalendarTab extends ConsumerStatefulWidget {
  const StaysCalendarTab({super.key, required this.facilityId});

  final String facilityId;

  @override
  ConsumerState<StaysCalendarTab> createState() => _StaysCalendarTabState();
}

class _StaysCalendarTabState extends ConsumerState<StaysCalendarTab> {
  String? _listingId;

  /// The first of the month shown; null until "today" is known.
  LocalDate? _month;

  String get _fid => widget.facilityId;

  @override
  Widget build(BuildContext context) {
    final controlsAsync = ref.watch(stayControlsProvider(_fid));
    final listingsAsync = ref.watch(stayListingsProvider(_fid));
    if (controlsAsync.hasError || listingsAsync.hasError) {
      return StaysEmptyState.error(
        onRetry: () {
          ref.invalidate(stayControlsProvider(_fid));
          ref.invalidate(stayListingsProvider(_fid));
        },
      );
    }
    final controls = controlsAsync.value;
    final allListings = listingsAsync.value;
    if (controls == null || allListings == null) return const Center(child: CircularProgressIndicator());

    final canManage = ref.watch(stayPermissionProvider((_fid, PermissionType.manageStays))).value ?? false;
    final canSetUp = ref.watch(stayPermissionProvider((_fid, PermissionType.manageStaySettings))).value ?? false;
    final today = staysTodayFor(controls, ref.watch(facilityClockProvider));
    if (today == null) {
      return StaysEmptyState(
        icon: Icons.public,
        title: 'Confirm the time zone first',
        subtitle: 'Every night on this calendar is read in the facility’s time zone, so it must be confirmed in setup.',
        actionLabel: canSetUp ? 'Open setup' : null,
        onAction: canSetUp ? () => context.go(AppRoute.staysSetupFor(_fid)) : null,
      );
    }
    final listings = allListings.where((l) => !l.archived).toList();
    if (listings.isEmpty) {
      return StaysEmptyState(
        icon: Icons.home_work_outlined,
        title: 'No listings yet',
        subtitle: 'Add your homes, cabins and RV sites to see their calendars.',
        actionLabel: canSetUp ? 'Open setup' : null,
        onAction: canSetUp ? () => context.go(AppRoute.staysSetupFor(_fid)) : null,
      );
    }
    final listing = listings.firstWhere((l) => l.id == _listingId, orElse: () => listings.first);
    final month = _month ?? today.firstOfMonth;
    final (from, to) = monthGridRange(month);

    final staysAsync = ref.watch(staysInRangeProvider(StayRangeKey(_fid, from, to)));
    final blocksAsync = ref.watch(stayChannelBlocksProvider(_fid));
    final conflicts = (ref.watch(stayConflictSummariesProvider(_fid)).value ?? const <StayConflictSummary>[])
        .where((c) => c.listingId == listing.id)
        .toList();

    final minMonth = today.addDays(-60).firstOfMonth;
    final maxMonth = today.addDays(539).firstOfMonth;

    Widget grid;
    if (staysAsync.hasError || blocksAsync.hasError) {
      grid = Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          children: [
            const Text("Couldn't load this month. Check your connection and try again."),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: () {
                ref.invalidate(staysInRangeProvider(StayRangeKey(_fid, from, to)));
                ref.invalidate(stayChannelBlocksProvider(_fid));
              },
              icon: const Icon(Icons.refresh),
              label: const Text('Retry'),
            ),
          ],
        ),
      );
    } else if (staysAsync.value == null || blocksAsync.value == null) {
      grid = const Padding(padding: EdgeInsets.all(32), child: Center(child: CircularProgressIndicator()));
    } else {
      final monthGrid = buildStayMonthGrid(
        listingId: listing.id,
        month: month,
        today: today,
        stays: staysAsync.value ?? const <Stay>[],
        channelBlocks: blocksAsync.value ?? const <StayChannelBlocks>[],
      );
      grid = StayMonthCalendar(
        key: Key('stay-month-${listing.id}-${month.monthKey}'),
        grid: monthGrid,
        onTapCell: (cell) => showStayNightSheet(
          context,
          facilityId: _fid,
          listingId: listing.id,
          listingName: listing.name,
          cell: cell,
          canManage: canManage,
        ),
      );
    }

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Wrap(
          spacing: 12,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            ConstrainedBox(
              constraints: const BoxConstraints(minWidth: 200, maxWidth: 360),
              child: DropdownButtonFormField<String>(
                key: const Key('stays-calendar-listing'),
                initialValue: listing.id,
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'Listing', isDense: true),
                items: [for (final l in listings) DropdownMenuItem(value: l.id, child: Text(_listingLabel(l)))],
                onChanged: (id) => setState(() => _listingId = id),
              ),
            ),
            if (canManage)
              FilledButton.tonalIcon(
                key: const Key('stays-calendar-block'),
                onPressed: () => showQuickBlockSheet(context, facilityId: _fid, listingId: listing.id),
                icon: const Icon(Icons.block),
                label: const Text('Block dates'),
              ),
          ],
        ),
        if (conflicts.isNotEmpty) ...[
          const SizedBox(height: 12),
          StayConflictBanner(
            conflicts: conflicts,
            syncEnabled: controls.icalSyncEnabled,
            onOpen: (stay) => showStayPeekSheet(context, facilityId: _fid, stay: stay, canManage: canManage),
          ),
        ],
        const SizedBox(height: 12),
        Row(
          children: [
            IconButton(
              key: const Key('stays-calendar-prev'),
              tooltip: 'Previous month',
              onPressed: month.isAfter(minMonth) ? () => setState(() => _month = month.addDays(-1).firstOfMonth) : null,
              icon: const Icon(Icons.chevron_left),
            ),
            Expanded(
              child: Text(
                monthTitle(month),
                key: const Key('stays-calendar-month'),
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
              ),
            ),
            IconButton(
              key: const Key('stays-calendar-next'),
              tooltip: 'Next month',
              onPressed: month.isBefore(maxMonth) ? () => setState(() => _month = month.firstOfNextMonth) : null,
              icon: const Icon(Icons.chevron_right),
            ),
            TextButton(
              onPressed: month == today.firstOfMonth ? null : () => setState(() => _month = today.firstOfMonth),
              child: const Text('Today'),
            ),
          ],
        ),
        grid,
        const SizedBox(height: 12),
        const StayCalendarLegend(),
      ],
    );
  }

  static String _listingLabel(StayListing l) => l.shortCode.isEmpty ? l.name : '${l.name} (${l.shortCode})';
}
