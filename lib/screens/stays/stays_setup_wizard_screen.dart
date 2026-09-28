import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'package:sfcapp/models/stays/stay_channel.dart';
import 'package:sfcapp/models/stays/stay_controls.dart';
import 'package:sfcapp/models/stays/stay_export_link.dart';
import 'package:sfcapp/models/stays/stay_listing.dart';
import 'package:sfcapp/models/stays/stays_callable_models.dart';
import 'package:sfcapp/providers/stays_providers.dart';
import 'package:sfcapp/router/app_route.dart';
import 'package:sfcapp/services/stays/stays_display.dart';
import 'package:sfcapp/theme/app_theme.dart';
import 'package:sfcapp/utils/time_zone_helper.dart';
import 'package:sfcapp/widgets/stays/stay_channels_panel.dart';
import 'package:sfcapp/widgets/stays/stay_listing_form_dialog.dart';
import 'package:sfcapp/widgets/stays/stays_empty_state.dart';
import 'package:sfcapp/widgets/stays/stays_feedback.dart';

/// The zones offered first; a zone already on the facility or on Stays is
/// added when it is not one of these.
const List<String> staysSetupZones = [
  'America/New_York',
  'America/Chicago',
  'America/Denver',
  'America/Phoenix',
  'America/Los_Angeles',
  'America/Anchorage',
  'Pacific/Honolulu',
];

enum StaysSetupStep { timeZone, listings, turnOn, calendars, done }

extension on StaysSetupStep {
  String get title => switch (this) {
        StaysSetupStep.timeZone => 'Confirm your time zone',
        StaysSetupStep.listings => 'Add your listings',
        StaysSetupStep.turnOn => 'Turn on Stays',
        StaysSetupStep.calendars => 'Connect calendars',
        StaysSetupStep.done => 'All set',
      };
}

/// The setup wizard (spec §1.1 K). The time zone is confirmed explicitly,
/// never picked for the owner; listings are added; Stays is turned on (the
/// server connects calendars only once it is on); then each listing's
/// Airbnb, VRBO or Booking.com calendar is pasted and previewed, and its SFC
/// links are shown with Copy. Every write goes through a Stays callable.
class StaysSetupWizardScreen extends ConsumerStatefulWidget {
  const StaysSetupWizardScreen({super.key, required this.facilityId});

  final String facilityId;

  @override
  ConsumerState<StaysSetupWizardScreen> createState() => _StaysSetupWizardScreenState();
}

class _StaysSetupWizardScreenState extends ConsumerState<StaysSetupWizardScreen> {
  StaysSetupStep _step = StaysSetupStep.timeZone;

  /// The zone picked on this visit; nothing is picked until the owner does.
  String? _zone;
  bool _changingZone = false;

  /// Confirmed on this visit (the server accepted it).
  String? _confirmedZone;
  bool _turnedOn = false;
  bool _busy = false;
  String? _error;
  List<StaysWarning> _warnings = const [];

  String get _fid => widget.facilityId;

  String? _canonical(String? zone) => ref.read(facilityClockProvider).canonicalZone(zone) ?? zone;

  Future<void> _confirmZone() async {
    final zone = _zone;
    if (zone == null || _busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final result = await ref.read(staysCallablesProvider).setControls(StaysSetControlsRequest(
            facilityId: _fid,
            changes: StayControlsChanges(timeZone: zone),
            confirmTimeZone: true,
          ));
      if (!mounted) return;
      setState(() {
        _confirmedZone = zone;
        _changingZone = false;
        _warnings = result.warnings;
      });
    } catch (e) {
      if (mounted) setState(() => _error = staysErrorMessage(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _turnOn() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref.read(staysCallablesProvider).setControls(StaysSetControlsRequest(
            facilityId: _fid,
            changes: const StayControlsChanges(moduleEnabled: true),
          ));
      if (mounted) setState(() => _turnedOn = true);
    } catch (e) {
      if (mounted) setState(() => _error = staysErrorMessage(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _go(StaysSetupStep step) => setState(() {
        _step = step;
        _error = null;
      });

  bool _zoneConfirmed(StayControls c) => _confirmedZone != null || (c.isTimeZoneConfirmed && !_changingZone);

  bool _canContinue(StayControls controls, List<StayListing> listings) => switch (_step) {
        StaysSetupStep.timeZone => _zoneConfirmed(controls),
        StaysSetupStep.listings => listings.isNotEmpty,
        StaysSetupStep.turnOn => controls.moduleEnabled || _turnedOn,
        StaysSetupStep.calendars => true,
        StaysSetupStep.done => false,
      };

  @override
  Widget build(BuildContext context) {
    final controlsAsync = ref.watch(stayControlsProvider(_fid));
    final listingsAsync = ref.watch(stayListingsProvider(_fid));
    if (controlsAsync.hasError || listingsAsync.hasError) {
      return StaysEmptyState.error(
        title: "Couldn't load Stays setup",
        onRetry: () {
          ref.invalidate(stayControlsProvider(_fid));
          ref.invalidate(stayListingsProvider(_fid));
        },
      );
    }
    final controls = controlsAsync.value;
    final allListings = listingsAsync.value;
    if (controls == null || allListings == null) return const Center(child: CircularProgressIndicator());
    final listings = allListings.where((l) => !l.archived).toList();

    final theme = Theme.of(context);
    final stepIndex = _step.index;
    final total = StaysSetupStep.values.length;

    final Widget body = switch (_step) {
      StaysSetupStep.timeZone => _timeZoneStep(controls),
      StaysSetupStep.listings => _listingsStep(allListings, listings),
      StaysSetupStep.turnOn => _turnOnStep(controls),
      StaysSetupStep.calendars => _calendarsStep(controls, listings),
      StaysSetupStep.done => _doneStep(controls, listings),
    };

    return Column(
      key: const Key('stays-setup'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Set up Stays', style: theme.textTheme.headlineSmall),
              const SizedBox(height: 4),
              Text(
                'Step ${stepIndex + 1} of $total · ${_step.title}',
                key: const Key('stays-setup-step'),
                style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
              ),
              const SizedBox(height: 8),
              LinearProgressIndicator(value: (stepIndex + 1) / total),
            ],
          ),
        ),
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                body,
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Text(_error!, key: const Key('stays-setup-error'), style: TextStyle(color: theme.colorScheme.error)),
                  ),
              ],
            ),
          ),
        ),
        if (_step != StaysSetupStep.done)
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  if (stepIndex > 0)
                    TextButton(
                      key: const Key('stays-setup-back'),
                      onPressed: _busy ? null : () => _go(StaysSetupStep.values[stepIndex - 1]),
                      child: const Text('Back'),
                    ),
                  const Spacer(),
                  FilledButton(
                    key: const Key('stays-setup-next'),
                    onPressed: !_busy && _canContinue(controls, listings)
                        ? () => _go(StaysSetupStep.values[stepIndex + 1])
                        : null,
                    child: Text(_step == StaysSetupStep.calendars ? 'Finish' : 'Next'),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }

  // --- Step 1: time zone ------------------------------------------------------

  Widget _timeZoneStep(StayControls controls) {
    final scheme = Theme.of(context).colorScheme;
    final facilityZone = ref.watch(staysFacilityTimeZoneProvider(_fid));
    final confirmed = _confirmedZone ?? (controls.isTimeZoneConfirmed && !_changingZone ? controls.timeZone : null);
    final intro = Text(
      'Every booking date in Stays is a night in your facility’s time zone, and “today” is worked out there. '
      'Pick the zone and confirm it. Stays never picks one for you.',
      style: TextStyle(color: scheme.onSurfaceVariant),
    );

    final mismatchWarnings = _warnings.where((w) => w.code == StaysWarningCodes.facilityTimezoneMismatch).toList();
    if (confirmed != null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          intro,
          const SizedBox(height: 16),
          Row(
            children: [
              const Icon(Icons.check_circle, color: AppTheme.success),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Confirmed: ${TimeZoneHelper.displayLabel(confirmed)} ($confirmed)',
                  key: const Key('stays-setup-zone-confirmed'),
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
              ),
              TextButton(
                onPressed: _busy
                    ? null
                    : () => setState(() {
                          _changingZone = true;
                          _confirmedZone = null;
                          _zone = null;
                          _warnings = const [];
                        }),
                child: const Text('Change'),
              ),
            ],
          ),
          for (final w in mismatchWarnings) _warning(w.message),
        ],
      );
    }

    final options = <String>{
      ...staysSetupZones,
      if (controls.timeZone != null) controls.timeZone!,
      if (facilityZone != null && facilityZone.isNotEmpty && ref.read(facilityClockProvider).isValidZone(facilityZone))
        _canonical(facilityZone)!,
    }.toList();
    final picked = _zone;
    final facilityCanonical = _canonical(facilityZone);
    final mismatch = picked != null && facilityCanonical != null && _canonical(picked) != facilityCanonical;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        intro,
        const SizedBox(height: 16),
        InputDecorator(
          decoration: const InputDecoration(labelText: 'Facility time zone'),
          child: DropdownButtonHideUnderline(
            child: DropdownButton<String>(
              key: const Key('stays-setup-zone'),
              // Controlled: nothing is shown until the owner picks.
              value: picked,
              isExpanded: true,
              isDense: true,
              hint: const Text('Choose a time zone'),
              items: [
                for (final z in options) DropdownMenuItem(value: z, child: Text('${TimeZoneHelper.displayLabel(z)} ($z)')),
              ],
              onChanged: _busy ? null : (z) => setState(() => _zone = z),
            ),
          ),
        ),
        if (facilityZone != null && facilityZone.isNotEmpty) ...[
          const SizedBox(height: 8),
          Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text('Your facility settings say ${TimeZoneHelper.displayLabel(facilityZone)} ($facilityZone). ',
                  style: TextStyle(color: scheme.onSurfaceVariant)),
              if (options.contains(facilityCanonical) && picked != facilityCanonical)
                TextButton(
                  key: const Key('stays-setup-use-facility-zone'),
                  onPressed: _busy ? null : () => setState(() => _zone = facilityCanonical),
                  child: const Text('Use it'),
                ),
            ],
          ),
        ],
        if (mismatch)
          _warning(
            'This is not the zone in your facility settings (${TimeZoneHelper.displayLabel(facilityCanonical)}). '
            'If the facility setting is wrong, fix it in Facility settings; Stays will use the zone you confirm here.',
            key: const Key('stays-setup-zone-mismatch'),
          ),
        const SizedBox(height: 16),
        Align(
          alignment: Alignment.centerLeft,
          child: FilledButton.icon(
            key: const Key('stays-setup-confirm-zone'),
            onPressed: picked == null || _busy ? null : _confirmZone,
            icon: const Icon(Icons.check),
            label: Text(picked == null ? 'Confirm time zone' : 'Confirm ${TimeZoneHelper.displayLabel(picked)}'),
          ),
        ),
      ],
    );
  }

  Widget _warning(String text, {Key? key}) => Padding(
        padding: const EdgeInsets.only(top: 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Icon(Icons.warning_amber_rounded, color: AppTheme.warning, size: 20),
            const SizedBox(width: 8),
            Expanded(child: Text(text, key: key)),
          ],
        ),
      );

  // --- Step 2: listings -------------------------------------------------------

  Widget _listingsStep(List<StayListing> all, List<StayListing> listings) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Add each thing you rent by the night: a home you list on Airbnb, the house, a cabin, an RV site. '
          'You can add more, and fill in the details, later.',
          style: TextStyle(color: scheme.onSurfaceVariant),
        ),
        const SizedBox(height: 12),
        for (final l in listings)
          Card(
            key: Key('stays-setup-listing-${l.id}'),
            child: ListTile(
              leading: const Icon(Icons.home_work_outlined),
              title: Text(l.name),
              subtitle: Text([
                listingKindLabel(l.kind),
                if (l.shortCode.isNotEmpty) l.shortCode,
                if (l.rates.nightly > 0) '${centsLabel(l.rates.nightly)} a night',
              ].join(' · ')),
            ),
          ),
        if (listings.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Text('No listings yet.', style: TextStyle(color: scheme.onSurfaceVariant)),
          ),
        const SizedBox(height: 8),
        Align(
          alignment: Alignment.centerLeft,
          child: OutlinedButton.icon(
            key: const Key('stays-setup-add-listing'),
            // The new listing shows up in the list above as soon as it is saved.
            onPressed: () => showStayListingFormDialog(context, facilityId: _fid, existing: all),
            icon: const Icon(Icons.add),
            label: const Text('Add a listing'),
          ),
        ),
      ],
    );
  }

  // --- Step 3: turn on --------------------------------------------------------

  Widget _turnOnStep(StayControls controls) {
    final scheme = Theme.of(context).colorScheme;
    if (controls.moduleEnabled || _turnedOn) {
      return const Row(
        key: Key('stays-setup-on'),
        children: [
          Icon(Icons.check_circle, color: AppTheme.success),
          SizedBox(width: 8),
          Expanded(child: Text('Stays is on for this facility.', style: TextStyle(fontWeight: FontWeight.w600))),
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Turning Stays on shows it to your team at this facility and lets you connect calendars. '
          'Stays sends nothing to guests: no emails and no texts.',
          style: TextStyle(color: scheme.onSurfaceVariant),
        ),
        const SizedBox(height: 16),
        FilledButton.icon(
          key: const Key('stays-setup-turn-on'),
          onPressed: _busy ? null : _turnOn,
          icon: const Icon(Icons.power_settings_new),
          label: const Text('Turn on Stays'),
        ),
      ],
    );
  }

  // --- Step 4: calendars --------------------------------------------------------

  Widget _calendarsStep(StayControls controls, List<StayListing> listings) {
    final scheme = Theme.of(context).colorScheme;
    final channels = ref.watch(stayChannelsProvider(_fid)).value ?? const <StayChannel>[];
    final links = ref.watch(stayExportLinksProvider(_fid)).value ?? const <StayExportLink>[];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'For each listing on Airbnb, VRBO or Booking.com, paste its Export calendar link. Stays shows what it '
          'found before connecting, then checks it every 30 minutes. You can skip this and add calendars later.',
          style: TextStyle(color: scheme.onSurfaceVariant),
        ),
        const SizedBox(height: 12),
        for (final listing in listings) ...[
          StayListingChannelsCard(
            facilityId: _fid,
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

  // --- Done ---------------------------------------------------------------------

  Widget _doneStep(StayControls controls, List<StayListing> listings) {
    final channels = ref.watch(stayChannelsProvider(_fid)).value ?? const <StayChannel>[];
    final active = channels.where((c) => c.active).length;
    final zone = _confirmedZone ?? controls.timeZone ?? '';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Row(
          children: [
            Icon(Icons.check_circle, color: AppTheme.success, size: 32),
            SizedBox(width: 12),
            Expanded(child: Text('Stays is set up.', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600))),
          ],
        ),
        const SizedBox(height: 12),
        Text('Time zone: ${TimeZoneHelper.displayLabel(zone)} ($zone)'),
        Text('Listings: ${listings.length}'),
        Text('Calendars connected: $active'),
        const SizedBox(height: 12),
        const Text(
          'For the first week, compare the Stays calendar with the Airbnb app each day before you turn on '
          'sending your SFC calendar to other sites.',
        ),
        const SizedBox(height: 16),
        FilledButton.icon(
          key: const Key('stays-setup-open-calendar'),
          onPressed: () => context.go(AppRoute.staysWithTab(facilityId: _fid, tab: 'calendar')),
          icon: const Icon(Icons.calendar_month),
          label: const Text('Open the calendar'),
        ),
      ],
    );
  }
}
