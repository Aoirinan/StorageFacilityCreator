import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:sfcapp/models/stays/stay_channel.dart';
import 'package:sfcapp/models/stays/stay_controls.dart';
import 'package:sfcapp/models/stays/stay_enums.dart';
import 'package:sfcapp/models/stays/stay_export_link.dart';
import 'package:sfcapp/models/stays/stay_listing.dart';
import 'package:sfcapp/models/stays/stays_callable_models.dart';
import 'package:sfcapp/providers/stays_providers.dart';
import 'package:sfcapp/services/stays/stays_channel_health.dart';
import 'package:sfcapp/services/stays/stays_display.dart';
import 'package:sfcapp/theme/app_theme.dart';
import 'package:sfcapp/utils/request_id.dart';
import 'package:sfcapp/widgets/stays/stays_feedback.dart';

// Channel management for owners and managers (spec §1.1 F and G): the
// calendars a listing imports (with a preview before saving, Sync now and
// Remove) and the SFC links other sites import. The import URL is a secret
// the server keeps; the app sends it once and never reads it back.

/// Honest timing for export links: Stays cannot make a channel read sooner.
const String staysExportTimingNote =
    'Airbnb and the other sites read this link on their own schedule, often only every few hours. '
    'A block you add in Stays can take that long to show there, so when a guest could book soon, '
    'block the dates in the Airbnb app too.';

/// The two switches that decide whether calendars move at all.
class StaysSyncSwitchesCard extends ConsumerStatefulWidget {
  const StaysSyncSwitchesCard({super.key, required this.facilityId, required this.controls});

  final String facilityId;
  final StayControls controls;

  @override
  ConsumerState<StaysSyncSwitchesCard> createState() => _StaysSyncSwitchesCardState();
}

class _StaysSyncSwitchesCardState extends ConsumerState<StaysSyncSwitchesCard> {
  bool _saving = false;

  Future<void> _set(StayControlsChanges changes, String done) async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      await ref.read(staysCallablesProvider).setControls(StaysSetControlsRequest(
            facilityId: widget.facilityId,
            changes: changes,
          ));
      if (mounted) showStaysSnack(context, done);
    } catch (e) {
      if (mounted) showStaysSnack(context, staysErrorMessage(e), error: true);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _toggleExport(bool on) async {
    if (on) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Start sending your SFC calendar?'),
          content: const Text(
            'Sites that import your SFC links will start seeing the dates those links cover. '
            'Turn this on after about a week of checking that the Stays calendar matches the Airbnb app. '
            '$staysExportTimingNote',
          ),
          actions: [
            TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Not yet')),
            FilledButton(onPressed: () => Navigator.of(context).pop(true), child: const Text('Start sending')),
          ],
        ),
      );
      if (ok != true) return;
    }
    await _set(
      StayControlsChanges(icalExportEnabled: on),
      on ? 'Your SFC links now send your calendar.' : 'Your SFC links are paused. Sites keep the dates they already have.',
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controls;
    return Card(
      child: Column(
        children: [
          SwitchListTile(
            key: const Key('stays-switch-import'),
            title: const Text('Check calendars every 30 minutes'),
            subtitle: const Text('Bookings and blocked dates from Airbnb and the other sites show up in Stays.'),
            value: c.icalSyncEnabled,
            onChanged: _saving
                ? null
                : (on) => _set(
                      StayControlsChanges(icalSyncEnabled: on),
                      on ? 'Stays now checks your calendars every 30 minutes.' : 'Automatic checks are off. Sync now still works.',
                    ),
          ),
          const Divider(height: 1),
          SwitchListTile(
            key: const Key('stays-switch-export'),
            title: const Text('Send your SFC calendar to other sites'),
            subtitle: Text(c.icalExportEnabled
                ? 'On. Your SFC links answer with the dates they cover.'
                : 'Off. Your SFC links answer "try again later", and sites keep the dates they already have.'),
            value: c.icalExportEnabled,
            onChanged: _saving ? null : _toggleExport,
          ),
        ],
      ),
    );
  }
}

/// A listing's calendars: the ones it imports and the SFC links it sends.
class StayListingChannelsCard extends ConsumerStatefulWidget {
  const StayListingChannelsCard({
    super.key,
    required this.facilityId,
    required this.listing,
    required this.controls,
    this.channels = const [],
    this.exportLinks = const [],
  });

  final String facilityId;
  final StayListing listing;
  final StayControls controls;

  /// This listing's channels (inactive ones are left out here).
  final List<StayChannel> channels;
  final List<StayExportLink> exportLinks;

  @override
  ConsumerState<StayListingChannelsCard> createState() => _StayListingChannelsCardState();
}

class _StayListingChannelsCardState extends ConsumerState<StayListingChannelsCard> {
  final Set<String> _busy = {};

  /// A create that failed keeps its id, so trying again cannot make a second link.
  final Map<ExportTargetProvider, String> _pendingExport = {};

  /// The URLs this session has shown, by link id.
  final Map<String, String> _shownUrls = {};

  bool _isBusy(String key) => _busy.contains(key);

  Future<void> _run(String key, Future<void> Function() action) async {
    if (_busy.contains(key)) return;
    setState(() => _busy.add(key));
    try {
      await action();
    } catch (e) {
      if (mounted) showStaysSnack(context, staysErrorMessage(e), error: true);
    } finally {
      if (mounted) setState(() => _busy.remove(key));
    }
  }

  Future<void> _addChannel() async {
    final saved = await showDialog<StaysChannelSaved>(
      context: context,
      builder: (_) => StayAddChannelDialog(facilityId: widget.facilityId, listing: widget.listing),
    );
    if (saved == null || !mounted) return;
    final first = saved.firstSync;
    final summary = first.status.isHealthy
        ? 'Connected. First sync: ${first.created} new booking(s), ${first.blocks} blocked range(s).'
        : 'Connected, but the first sync did not finish: ${channelStatusProblem(first.status, httpStatus: first.httpStatus)}';
    showStaysSnack(context, summary, error: !first.status.isHealthy);
    // Pasting a calendar turns on the 30-minute checks (spec §11.4); without
    // them the calendar would only ever be read on Sync now.
    if (!widget.controls.icalSyncEnabled) {
      try {
        await ref.read(staysCallablesProvider).setControls(StaysSetControlsRequest(
              facilityId: widget.facilityId,
              changes: const StayControlsChanges(icalSyncEnabled: true),
            ));
      } catch (e) {
        if (mounted) {
          showStaysSnack(
            context,
            'The calendar is connected, but automatic checks could not be turned on: ${staysErrorMessage(e)}',
            error: true,
          );
        }
      }
    }
  }

  Future<void> _syncNow(StayChannel channel) => _run('sync:${channel.id}', () async {
        final results = await ref.read(staysCallablesProvider).syncNow(facilityId: widget.facilityId, channelId: channel.id);
        if (!mounted) return;
        final r = results.isEmpty ? null : results.first;
        if (r == null || r.skipped) {
          showStaysSnack(context, 'That calendar was checked less than a minute ago.');
        } else if (r.status.isHealthy) {
          showStaysSnack(context, 'Synced. ${r.created} new, ${r.dateChanged} changed, ${r.removed} removed.');
        } else {
          showStaysSnack(context, channelStatusProblem(r.status, httpStatus: r.httpStatus), error: true);
        }
      });

  Future<void> _remove(StayChannel channel) async {
    final label = channel.label.isEmpty ? channelProviderLabel(channel.provider) : channel.label;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Remove $label?'),
        content: const Text(
          'Stays stops reading this calendar. Bookings it brought in stay on the calendar, marked as no longer synced, '
          'and the dates it had blocked are freed. Nothing changes on the other site.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Keep')),
          FilledButton(
            key: const Key('stays-channel-remove-confirm'),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await _run('remove:${channel.id}', () async {
      await ref.read(staysCallablesProvider).removeChannel(facilityId: widget.facilityId, channelId: channel.id);
      if (mounted) showStaysSnack(context, '$label removed.');
    });
  }

  Future<void> _createExport(ExportTargetProvider target) => _run('export:${target.wire}', () async {
        final requestId = _pendingExport.putIfAbsent(target, newRequestId);
        final link = await ref.read(staysCallablesProvider).createExportLink(
              facilityId: widget.facilityId,
              listingId: widget.listing.id,
              targetProvider: target,
              label: 'SFC to ${exportTargetLabel(target)}',
              requestId: requestId,
            );
        _pendingExport.remove(target);
        await Clipboard.setData(ClipboardData(text: link.url));
        if (!mounted) return;
        setState(() => _shownUrls[link.linkId] = link.url);
        showStaysSnack(context, 'Link made and copied. Paste it into ${exportTargetLabel(target)}’s Import calendar.');
      });

  Future<void> _copyExport(StayExportLink link) => _run('copy:${link.id}', () async {
        final url = _shownUrls[link.id] ??
            (await ref.read(staysCallablesProvider).getExportUrl(facilityId: widget.facilityId, linkId: link.id)).url;
        await Clipboard.setData(ClipboardData(text: url));
        if (!mounted) return;
        setState(() => _shownUrls[link.id] = url);
        showStaysSnack(context, 'Link copied.');
      });

  Future<void> _revokeExport(StayExportLink link) async {
    final site = exportTargetLabel(link.targetProvider);
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Turn off this link?'),
        content: Text(
          'The link stops working at once. $site keeps the last dates it read until you remove the link there too.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Keep')),
          FilledButton(onPressed: () => Navigator.of(context).pop(true), child: const Text('Turn off')),
        ],
      ),
    );
    if (ok != true) return;
    await _run('revoke:${link.id}', () async {
      await ref.read(staysCallablesProvider).revokeExportLink(facilityId: widget.facilityId, linkId: link.id);
      if (!mounted) return;
      setState(() => _shownUrls.remove(link.id));
      showStaysSnack(context, 'Link turned off.');
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final now = ref.watch(facilityClockProvider).nowUtc();
    final channels = widget.channels.where((c) => c.active).toList()
      ..sort((a, b) => (a.createdAt ?? DateTime(0)).compareTo(b.createdAt ?? DateTime(0)));
    final links = widget.exportLinks.where((l) => l.active && l.listingId == widget.listing.id).toList();
    final usedTargets = links.map((l) => l.targetProvider).toSet();

    return Card(
      key: Key('stays-channels-${widget.listing.id}'),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(widget.listing.name, style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
            Text(listingKindLabel(widget.listing.kind), style: TextStyle(color: scheme.onSurfaceVariant)),
            const SizedBox(height: 12),
            Text('Calendars coming in', style: theme.textTheme.titleSmall),
            const SizedBox(height: 4),
            Text(
              'Paste the Export calendar link from Airbnb (or VRBO, Booking.com). Stays reads it every 30 minutes; '
              'a change on Airbnb shows here within about half an hour.',
              style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13),
            ),
            if (channels.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Text('No calendars connected yet.', style: TextStyle(color: scheme.onSurfaceVariant)),
              ),
            for (final channel in channels)
              _ChannelTile(
                channel: channel,
                health: describeChannelHealth(channel, now: now, exportLinks: widget.exportLinks),
                syncing: _isBusy('sync:${channel.id}'),
                removing: _isBusy('remove:${channel.id}'),
                onSyncNow: () => _syncNow(channel),
                onRemove: () => _remove(channel),
              ),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                key: Key('stays-add-channel-${widget.listing.id}'),
                onPressed: _addChannel,
                icon: const Icon(Icons.add_link),
                label: const Text('Add a calendar'),
              ),
            ),
            const Divider(height: 24),
            Text('Your SFC calendar for other sites', style: theme.textTheme.titleSmall),
            const SizedBox(height: 4),
            Text(staysExportTimingNote, style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13)),
            if (!widget.controls.icalExportEnabled)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  'Sending is off for now, so these links answer "try again later". Turn it on after you have '
                  'checked for about a week that Stays matches the Airbnb app.',
                  key: const Key('stays-export-off-note'),
                  style: const TextStyle(color: AppTheme.warning, fontSize: 13),
                ),
              ),
            for (final link in links)
              _ExportLinkTile(
                link: link,
                fetchLine: exportFetchLine(link, now),
                shownUrl: _shownUrls[link.id],
                copying: _isBusy('copy:${link.id}'),
                onCopy: () => _copyExport(link),
                onRevoke: () => _revokeExport(link),
              ),
            Align(
              alignment: Alignment.centerLeft,
              child: PopupMenuButton<ExportTargetProvider>(
                key: Key('stays-add-export-${widget.listing.id}'),
                tooltip: 'Make an SFC link',
                onSelected: _createExport,
                itemBuilder: (_) => [
                  for (final t in exportTargets)
                    PopupMenuItem(
                      value: t,
                      enabled: !usedTargets.contains(t),
                      child: Text('For ${exportTargetLabel(t)}'),
                    ),
                ],
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.ios_share, size: 18, color: scheme.primary),
                      const SizedBox(width: 8),
                      Text('Make an SFC link', style: TextStyle(color: scheme.primary, fontWeight: FontWeight.w500)),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ChannelTile extends StatelessWidget {
  const _ChannelTile({
    required this.channel,
    required this.health,
    required this.syncing,
    required this.removing,
    required this.onSyncNow,
    required this.onRemove,
  });

  final StayChannel channel;
  final ChannelHealthView health;
  final bool syncing;
  final bool removing;
  final VoidCallback onSyncNow;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (icon, color) = switch (health.level) {
      ChannelHealthLevel.ok => (Icons.check_circle, AppTheme.success),
      ChannelHealthLevel.warning => (Icons.warning_amber_rounded, AppTheme.warning),
      ChannelHealthLevel.failing => (Icons.error, AppTheme.error),
      ChannelHealthLevel.neverSynced => (Icons.schedule, scheme.onSurfaceVariant),
    };
    final title = channel.label.isEmpty ? channelProviderLabel(channel.provider) : channel.label;
    return Padding(
      key: Key('stays-channel-${channel.id}'),
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: color, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('$title · ${channelProviderLabel(channel.provider)}', style: const TextStyle(fontWeight: FontWeight.w600)),
                if (channel.urlHost.isNotEmpty)
                  Text(channel.urlHost, style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12)),
                Text('${health.checkedLine} · ${health.syncedLine}', style: const TextStyle(fontSize: 13)),
                if (health.problem != null) Text(health.problem!, style: TextStyle(color: color, fontSize: 13)),
                if (health.exportFetchLine != null)
                  Text(health.exportFetchLine!, style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13)),
              ],
            ),
          ),
          Wrap(
            spacing: 4,
            children: [
              TextButton(
                key: Key('stays-sync-now-${channel.id}'),
                onPressed: syncing ? null : onSyncNow,
                child: syncing
                    ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Text('Sync now'),
              ),
              IconButton(
                key: Key('stays-channel-remove-${channel.id}'),
                tooltip: 'Remove calendar',
                onPressed: removing ? null : onRemove,
                icon: const Icon(Icons.link_off),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _ExportLinkTile extends StatelessWidget {
  const _ExportLinkTile({
    required this.link,
    required this.fetchLine,
    required this.shownUrl,
    required this.copying,
    required this.onCopy,
    required this.onRevoke,
  });

  final StayExportLink link;
  final String fetchLine;
  final String? shownUrl;
  final bool copying;
  final VoidCallback onCopy;
  final VoidCallback onRevoke;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      key: Key('stays-export-${link.id}'),
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.ios_share, size: 20, color: scheme.onSurfaceVariant),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  link.label.isEmpty ? 'SFC to ${exportTargetLabel(link.targetProvider)}' : link.label,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                Text('Sends: ${exportScopeLabel(link.scope)}', style: const TextStyle(fontSize: 13)),
                Text(fetchLine, style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13)),
                if (shownUrl != null)
                  SelectableText(shownUrl!, style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
              ],
            ),
          ),
          Wrap(
            spacing: 4,
            children: [
              TextButton.icon(
                key: Key('stays-export-copy-${link.id}'),
                onPressed: copying ? null : onCopy,
                icon: const Icon(Icons.copy, size: 18),
                label: const Text('Copy'),
              ),
              IconButton(tooltip: 'Turn off link', onPressed: onRevoke, icon: const Icon(Icons.block)),
            ],
          ),
        ],
      ),
    );
  }
}

/// Paste a calendar link, see what Stays found in it, then connect it. The
/// server fetches the link (only from the channels' own hosts) for the
/// preview, and again when connecting.
class StayAddChannelDialog extends ConsumerStatefulWidget {
  const StayAddChannelDialog({super.key, required this.facilityId, required this.listing});

  final String facilityId;
  final StayListing listing;

  @override
  ConsumerState<StayAddChannelDialog> createState() => _StayAddChannelDialogState();
}

class _StayAddChannelDialogState extends ConsumerState<StayAddChannelDialog> {
  final _url = TextEditingController();
  final _label = TextEditingController();
  ChannelProvider _provider = ChannelProvider.airbnb;
  StaysChannelPreview? _preview;

  /// The link the preview was made from; connecting needs a preview of this exact link.
  String? _previewedUrl;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _url.dispose();
    _label.dispose();
    super.dispose();
  }

  StaysUpsertChannelRequest _request({required bool dryRun}) => StaysUpsertChannelRequest(
        facilityId: widget.facilityId,
        listingId: widget.listing.id,
        provider: _provider,
        label: _label.text.trim(),
        url: _url.text.trim(),
        dryRun: dryRun,
      );

  Future<void> _check() async {
    if (_busy) return;
    if (_url.text.trim().isEmpty) {
      setState(() => _error = 'Paste the calendar link first.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
      _preview = null;
    });
    try {
      final result = await ref.read(staysCallablesProvider).upsertChannel(_request(dryRun: true));
      if (!mounted) return;
      setState(() {
        _preview = result is StaysChannelPreview ? result : null;
        _previewedUrl = _url.text.trim();
      });
    } catch (e) {
      if (mounted) setState(() => _error = staysErrorMessage(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _connect() async {
    if (_busy || _preview == null || _previewedUrl != _url.text.trim()) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final result = await ref.read(staysCallablesProvider).upsertChannel(_request(dryRun: false));
      if (!mounted) return;
      if (result is StaysChannelSaved) {
        Navigator.of(context).pop(result);
        return;
      }
      setState(() => _error = 'The calendar was not connected. Try again.');
    } catch (e) {
      if (mounted) setState(() => _error = staysErrorMessage(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _changed() {
    if (_preview != null || _error != null) {
      setState(() {
        _preview = null;
        _error = null;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final preview = _preview;
    return AlertDialog(
      title: Text('Add a calendar to ${widget.listing.name}'),
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              DropdownButtonFormField<ChannelProvider>(
                key: const Key('stays-channel-provider'),
                initialValue: _provider,
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'Which site is it from?'),
                items: [
                  for (final p in importProviders) DropdownMenuItem(value: p, child: Text(channelProviderLabel(p))),
                ],
                onChanged: _busy
                    ? null
                    : (p) {
                        if (p == null) return;
                        setState(() => _provider = p);
                        _changed();
                      },
              ),
              const SizedBox(height: 8),
              if (_provider == ChannelProvider.airbnb)
                Text(
                  'In Airbnb: open the listing’s calendar, then Availability → Connect calendars → '
                  'Export calendar, and copy the link.',
                  style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13),
                ),
              TextField(
                key: const Key('stays-channel-url'),
                controller: _url,
                enabled: !_busy,
                decoration: const InputDecoration(labelText: 'Calendar link (.ics)', hintText: 'https://…'),
                onChanged: (_) => _changed(),
              ),
              TextField(
                key: const Key('stays-channel-label'),
                controller: _label,
                enabled: !_busy,
                maxLength: 60,
                decoration: const InputDecoration(labelText: 'Name (optional)', hintText: 'e.g. Airbnb – Blue House'),
              ),
              if (preview != null) _PreviewBox(preview: preview),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(_error!, key: const Key('stays-channel-error'), style: TextStyle(color: scheme.error)),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: _busy ? null : () => Navigator.of(context).pop(), child: const Text('Cancel')),
        if (preview == null)
          FilledButton(
            key: const Key('stays-channel-check'),
            onPressed: _busy ? null : _check,
            child: _busy
                ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                : const Text('Check link'),
          )
        else
          FilledButton(
            key: const Key('stays-channel-connect'),
            onPressed: _busy ? null : _connect,
            child: _busy
                ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                : const Text('Connect calendar'),
          ),
      ],
    );
  }
}

class _PreviewBox extends StatelessWidget {
  const _PreviewBox({required this.preview});

  final StaysChannelPreview preview;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final parts = <String>[
      'Found ${preview.reservations} upcoming reservation${preview.reservations == 1 ? '' : 's'}',
      '${preview.blocks} blocked range${preview.blocks == 1 ? '' : 's'}',
      if (preview.nextArrival != null) 'next arrival ${ymdLabel(preview.nextArrival!)}',
    ];
    return Container(
      key: const Key('stays-channel-preview'),
      margin: const EdgeInsets.only(top: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('${parts.join(', ')}.', style: const TextStyle(fontWeight: FontWeight.w600)),
          for (final w in preview.warnings)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(w.message, style: const TextStyle(color: AppTheme.warning, fontSize: 13)),
            ),
          const SizedBox(height: 4),
          Text(
            'Nothing is saved until you connect. Stays never sends anything to guests.',
            style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12),
          ),
        ],
      ),
    );
  }
}
