import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:sfcapp/models/stays/stay_enums.dart';
import 'package:sfcapp/models/stays/stay_listing.dart';
import 'package:sfcapp/models/stays/stays_callable_models.dart';
import 'package:sfcapp/providers/stays_providers.dart';
import 'package:sfcapp/services/stays/stays_display.dart';
import 'package:sfcapp/utils/local_date.dart';
import 'package:sfcapp/utils/request_id.dart';
import 'package:sfcapp/widgets/stays/stays_feedback.dart';

/// Block dates on a listing (owner use or maintenance), prefilled from the
/// calendar ([checkIn]/[checkOut] are 'YYYY-MM-DD', checkOut exclusive).
/// The block is a hard hold made by staysCreateStay, so a booking cannot
/// land on it; the server asks before blocking over a channel's own block,
/// and when a channel could still sell the dates before it reads ours.
Future<void> showQuickBlockSheet(
  BuildContext context, {
  required String facilityId,
  String? listingId,
  String? checkIn,
  String? checkOut,
}) =>
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => QuickBlockSheet(facilityId: facilityId, listingId: listingId, checkIn: checkIn, checkOut: checkOut),
    );

class QuickBlockSheet extends ConsumerStatefulWidget {
  const QuickBlockSheet({super.key, required this.facilityId, this.listingId, this.checkIn, this.checkOut});

  final String facilityId;
  final String? listingId;
  final String? checkIn;
  final String? checkOut;

  @override
  ConsumerState<QuickBlockSheet> createState() => _QuickBlockSheetState();
}

class _QuickBlockSheetState extends ConsumerState<QuickBlockSheet> {
  /// One id per sheet: a retry (or the confirmations below) never blocks twice.
  late final String _requestId = newRequestId();
  final _note = TextEditingController();
  String? _listingId;
  StayKind _kind = StayKind.ownerBlock;
  LocalDate? _from;

  /// The last night blocked (the block's checkOut is the day after).
  LocalDate? _through;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _listingId = widget.listingId;
    _from = LocalDate.tryParse(widget.checkIn);
    final out = LocalDate.tryParse(widget.checkOut);
    _through = out?.addDays(-1) ?? _from;
  }

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  Future<LocalDate?> _pick(LocalDate initial, LocalDate first, LocalDate last) async {
    DateTime asDate(LocalDate d) => DateTime(d.year, d.month, d.day);
    final picked = await showDatePicker(
      context: context,
      initialDate: asDate(initial.isBefore(first) ? first : initial),
      firstDate: asDate(first),
      lastDate: asDate(last),
    );
    // Only the calendar day is used, never the time or zone of the DateTime.
    return picked == null ? null : LocalDate(picked.year, picked.month, picked.day);
  }

  Future<bool> _confirm(String title, String body, String yes) async =>
      await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(title),
          content: Text(body),
          actions: [
            TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.of(context).pop(true), child: Text(yes)),
          ],
        ),
      ) ==
      true;

  Future<void> _save() async {
    final listingId = _listingId;
    final from = _from;
    final through = _through;
    if (_saving || listingId == null || from == null || through == null) return;
    if (through.isBefore(from)) {
      setState(() => _error = 'The last night is before the first.');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    var acknowledgeShortLead = false;
    var overrideSoftBlocks = false;
    try {
      while (true) {
        try {
          await ref.read(staysCallablesProvider).createStay(StaysCreateStayRequest(
                facilityId: widget.facilityId,
                requestId: _requestId,
                listingId: listingId,
                checkIn: from.toYmd(),
                checkOut: through.addDays(1).toYmd(),
                kind: _kind,
                source: StaySource.owner,
                notes: _note.text.trim().isEmpty ? null : _note.text.trim(),
                acknowledgeShortLead: acknowledgeShortLead ? true : null,
                overrideSoftBlocks: overrideSoftBlocks ? true : null,
              ));
          if (!mounted) return;
          showStaysSnack(context, 'Blocked ${describeNights(LocalDate.nights(from, through.addDays(1)).map((d) => d.toYmd()))}.');
          Navigator.of(context).pop();
          return;
        } on StaysCallableException catch (e) {
          if (!mounted) return;
          if (e.reason == StaysErrorReason.shortLeadAckRequired && !acknowledgeShortLead) {
            final ok = await _confirm(
              'Block these dates on the channel too',
              'This listing is also on another site, and it may not read the Stays calendar for a few hours. '
                  'Block the same dates in the Airbnb app (and any other site) so nobody books them meanwhile.',
              'I have blocked them there too',
            );
            if (!ok) break;
            acknowledgeShortLead = true;
            continue;
          }
          if (e.reason == StaysErrorReason.softBlock && !overrideSoftBlocks) {
            final dates = describeNights(e.softBlockDates);
            final ok = await _confirm(
              'Already blocked on a channel',
              '${dates.isEmpty ? 'Some of these nights are' : '$dates ${e.softBlockDates.length == 1 ? 'is' : 'are'}'} '
                  'already blocked on a channel. Block them in Stays as well?',
              'Block them',
            );
            if (!ok) break;
            overrideSoftBlocks = true;
            continue;
          }
          if (e.reason == StaysErrorReason.hardConflict) {
            final taken = e.conflictNights.map((n) => '${ymdLabel(n.date)} (${n.label})').join(', ');
            setState(() => _error = taken.isEmpty ? staysErrorMessage(e) : 'Already taken: $taken.');
          } else {
            setState(() => _error = staysErrorMessage(e));
          }
          break;
        }
      }
    } catch (e) {
      if (mounted) setState(() => _error = staysErrorMessage(e));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final listings = (ref.watch(stayListingsProvider(widget.facilityId)).value ?? const <StayListing>[])
        .where((l) => l.isBookable)
        .toList();
    final controls = ref.watch(stayControlsProvider(widget.facilityId)).value;
    final today = controls == null ? null : staysTodayFor(controls, ref.watch(facilityClockProvider));

    Widget body;
    if (controls == null) {
      body = const Center(child: CircularProgressIndicator());
    } else if (today == null) {
      body = const Text('Confirm the facility time zone in Stays setup before blocking dates.');
    } else {
      final from = _from ?? today;
      final through = _through ?? from;
      final last = today.addDays(539);
      body = Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InputDecorator(
            decoration: const InputDecoration(labelText: 'Listing'),
            child: DropdownButtonHideUnderline(
              child: DropdownButton<String>(
                key: const Key('stay-block-listing'),
                value: listings.any((l) => l.id == _listingId) ? _listingId : null,
                isExpanded: true,
                isDense: true,
                hint: const Text('Choose a listing'),
                items: [for (final l in listings) DropdownMenuItem(value: l.id, child: Text(l.name))],
                onChanged: _saving ? null : (id) => setState(() => _listingId = id),
              ),
            ),
          ),
          const SizedBox(height: 12),
          SegmentedButton<StayKind>(
            segments: const [
              ButtonSegment(value: StayKind.ownerBlock, label: Text('Owner use'), icon: Icon(Icons.person_outline)),
              ButtonSegment(value: StayKind.maintenanceBlock, label: Text('Maintenance'), icon: Icon(Icons.build_outlined)),
            ],
            selected: {_kind},
            onSelectionChanged: _saving ? null : (s) => setState(() => _kind = s.first),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  key: const Key('stay-block-from'),
                  onPressed: _saving
                      ? null
                      : () async {
                          final d = await _pick(from, today, last);
                          if (d == null) return;
                          setState(() {
                            _from = d;
                            if ((_through ?? d).isBefore(d)) _through = d;
                          });
                        },
                  child: Text('First night: ${weekdayDateLabel(from)}'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: OutlinedButton(
                  key: const Key('stay-block-through'),
                  onPressed: _saving
                      ? null
                      : () async {
                          final d = await _pick(through, from, last);
                          if (d != null) setState(() => _through = d);
                        },
                  child: Text('Last night: ${weekdayDateLabel(through)}'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            '${from.daysUntil(through) + 1} night(s). The listing is free again the morning of ${weekdayDateLabel(through.addDays(1))}.',
            style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _note,
            enabled: !_saving,
            maxLength: 2000,
            maxLines: 2,
            decoration: const InputDecoration(labelText: 'Note (optional)', helperText: staysTeamVisibleNote),
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(_error!, key: const Key('stay-block-error'), style: TextStyle(color: scheme.error)),
            ),
          const SizedBox(height: 12),
          FilledButton(
            key: const Key('stay-block-save'),
            onPressed: _saving || _listingId == null
                ? null
                : () {
                    _from ??= from;
                    _through ??= through;
                    _save();
                  },
            child: _saving
                ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                : const Text('Block dates'),
          ),
        ],
      );
    }

    return SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(20, 0, 20, 20 + MediaQuery.viewInsetsOf(context).bottom),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('Block dates', style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w600)),
              const SizedBox(height: 4),
              Text(
                'A block keeps the nights off Stays bookings. It reaches Airbnb only through an SFC link, on Airbnb’s schedule.',
                style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13),
              ),
              const SizedBox(height: 12),
              body,
            ],
          ),
        ),
      ),
    );
  }
}
