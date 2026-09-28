import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'package:sfcapp/models/permission_model.dart';
import 'package:sfcapp/models/stays/stay_channel.dart';
import 'package:sfcapp/providers/stays_providers.dart';
import 'package:sfcapp/router/app_route.dart';
import 'package:sfcapp/services/stays/stays_calendar_grid.dart';
import 'package:sfcapp/services/stays/stays_channel_health.dart';
import 'package:sfcapp/services/stays/stays_display.dart';
import 'package:sfcapp/theme/app_theme.dart';
import 'package:sfcapp/widgets/stays/stay_conflict_banner.dart';
import 'package:sfcapp/widgets/stays/stay_listing_form_dialog.dart';
import 'package:sfcapp/widgets/stays/stay_peek_sheet.dart';
import 'package:sfcapp/widgets/stays/stays_empty_state.dart';

/// Listings grouped (Airbnbs, house, RV park), each with its double-booking
/// flag and, for owners and managers, its calendar connections. Read-only
/// for staff.
class StaysListingsTab extends ConsumerWidget {
  const StaysListingsTab({super.key, required this.facilityId});

  final String facilityId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final listingsAsync = ref.watch(stayListingsProvider(facilityId));
    if (listingsAsync.hasError) {
      return StaysEmptyState.error(onRetry: () => ref.invalidate(stayListingsProvider(facilityId)));
    }
    final all = listingsAsync.value;
    if (all == null) return const Center(child: CircularProgressIndicator());

    final canManage = ref.watch(stayPermissionProvider((facilityId, PermissionType.manageStays))).value ?? false;
    final canChannels = ref.watch(stayPermissionProvider((facilityId, PermissionType.manageStayChannels))).value ?? false;
    final canSetUp = ref.watch(stayPermissionProvider((facilityId, PermissionType.manageStaySettings))).value ?? false;
    final conflicts = ref.watch(stayConflictSummariesProvider(facilityId)).value ?? const <StayConflictSummary>[];
    final channels = canChannels ? (ref.watch(stayChannelsProvider(facilityId)).value ?? const <StayChannel>[]) : const <StayChannel>[];
    final now = ref.watch(facilityClockProvider).nowUtc();
    final listings = all.where((l) => !l.archived).toList();
    final scheme = Theme.of(context).colorScheme;

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        if (conflicts.isNotEmpty) ...[
          StayConflictBanner(
            conflicts: conflicts,
            syncEnabled: ref.watch(stayControlsProvider(facilityId)).value?.icalSyncEnabled ?? false,
            showListing: true,
            onOpen: (stay) => showStayPeekSheet(context, facilityId: facilityId, stay: stay, canManage: canManage),
          ),
          const SizedBox(height: 12),
        ],
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            if (canManage)
              FilledButton.icon(
                key: const Key('stays-listings-add'),
                onPressed: () => showStayListingFormDialog(context, facilityId: facilityId, existing: all),
                icon: const Icon(Icons.add),
                label: const Text('Add listing'),
              ),
            if (canChannels)
              OutlinedButton.icon(
                onPressed: () => context.go(AppRoute.staysChannelsFor(facilityId: facilityId)),
                icon: const Icon(Icons.sync),
                label: const Text('Calendars'),
              ),
            if (canSetUp)
              OutlinedButton.icon(
                onPressed: () => context.go(AppRoute.staysSetupFor(facilityId)),
                icon: const Icon(Icons.checklist),
                label: const Text('Setup'),
              ),
          ],
        ),
        const SizedBox(height: 12),
        if (listings.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 24),
            child: Text('No listings yet. Add your homes, cabins and RV sites.', textAlign: TextAlign.center),
          ),
        for (final listing in listings)
          Builder(builder: (context) {
            final mine = channels.where((c) => c.active && c.listingId == listing.id).toList();
            final failing = mine
                .map((c) => describeChannelHealth(c, now: now).level)
                .where((l) => l == ChannelHealthLevel.failing || l == ChannelHealthLevel.warning)
                .length;
            final doubleBooked = conflicts.any((c) => c.listingId == listing.id);
            final details = <String>[
              listingKindLabel(listing.kind),
              if (listing.shortCode.isNotEmpty) listing.shortCode,
              if (listing.rates.nightly > 0) '${centsLabel(listing.rates.nightly)} a night',
              if (canChannels) mine.isEmpty ? 'No calendars' : '${mine.length} calendar${mine.length == 1 ? '' : 's'}',
            ];
            return Card(
              key: Key('stays-listing-${listing.id}'),
              child: ListTile(
                title: Text(listing.name),
                subtitle: Text(details.join(' · ')),
                trailing: Wrap(
                  spacing: 8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    if (doubleBooked)
                      const Chip(
                        label: Text('Double booked'),
                        labelStyle: TextStyle(color: AppTheme.error),
                        side: BorderSide(color: AppTheme.error),
                      ),
                    if (failing > 0) Icon(Icons.warning_amber_rounded, color: AppTheme.warning, semanticLabel: 'Calendar needs a look'),
                    if (canChannels)
                      IconButton(
                        tooltip: 'Calendars',
                        onPressed: () => context.go(AppRoute.staysChannelsFor(facilityId: facilityId, listingId: listing.id)),
                        icon: Icon(Icons.sync, color: scheme.primary),
                      ),
                  ],
                ),
              ),
            );
          }),
      ],
    );
  }
}
