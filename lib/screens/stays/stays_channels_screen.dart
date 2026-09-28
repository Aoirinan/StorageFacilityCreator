import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:sfcapp/providers/stays_providers.dart';
import 'package:sfcapp/widgets/stays/stay_channels_panel.dart';
import 'package:sfcapp/widgets/stays/stays_empty_state.dart';

/// Calendar feeds and export links (owner/manager): the two sync switches,
/// then one card per listing (or just [listingId]'s) with its imported
/// calendars, Sync now, Remove, and its SFC links with Copy.
class StaysChannelsScreen extends ConsumerWidget {
  const StaysChannelsScreen({super.key, required this.facilityId, this.listingId});

  final String facilityId;
  final String? listingId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controlsAsync = ref.watch(stayControlsProvider(facilityId));
    final listingsAsync = ref.watch(stayListingsProvider(facilityId));
    final channelsAsync = ref.watch(stayChannelsProvider(facilityId));
    final linksAsync = ref.watch(stayExportLinksProvider(facilityId));

    final failed = [controlsAsync, listingsAsync, channelsAsync, linksAsync].where((a) => a.hasError);
    if (failed.isNotEmpty) {
      return StaysEmptyState.error(
        title: "Couldn't load your calendars",
        onRetry: () {
          ref.invalidate(stayControlsProvider(facilityId));
          ref.invalidate(stayListingsProvider(facilityId));
          ref.invalidate(stayChannelsProvider(facilityId));
          ref.invalidate(stayExportLinksProvider(facilityId));
        },
      );
    }
    final controls = controlsAsync.value;
    final listings = listingsAsync.value;
    final channels = channelsAsync.value;
    final links = linksAsync.value;
    if (controls == null || listings == null || channels == null || links == null) {
      return const Center(child: CircularProgressIndicator());
    }

    final shown = listings.where((l) => !l.archived && (listingId == null || l.id == listingId)).toList();
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text('Calendars', style: Theme.of(context).textTheme.headlineSmall),
        const SizedBox(height: 8),
        StaysSyncSwitchesCard(facilityId: facilityId, controls: controls),
        const SizedBox(height: 12),
        if (shown.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 24),
            child: Text('No listings yet. Add your homes, cabins and RV sites in Stays setup first.', textAlign: TextAlign.center),
          ),
        for (final listing in shown) ...[
          StayListingChannelsCard(
            facilityId: facilityId,
            listing: listing,
            controls: controls,
            channels: channels.where((c) => c.listingId == listing.id).toList(),
            exportLinks: links.where((l) => l.listingId == listing.id).toList(),
          ),
          const SizedBox(height: 12),
        ],
      ],
    );
  }
}
