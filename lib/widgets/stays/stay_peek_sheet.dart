import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:sfcapp/models/stays/stay.dart';
import 'package:sfcapp/models/stays/stay_enums.dart';
import 'package:sfcapp/models/stays/stays_callable_models.dart';
import 'package:sfcapp/providers/stays_providers.dart';
import 'package:sfcapp/services/stays/stays_display.dart';
import 'package:sfcapp/theme/app_theme.dart';
import 'package:sfcapp/widgets/stays/stay_source_badge.dart';
import 'package:sfcapp/widgets/stays/stay_status_chip.dart';
import 'package:sfcapp/widgets/stays/stays_feedback.dart';

/// A booking or block at a glance, from the calendar. Owners and managers
/// ([canManage]) can remove an owner or maintenance block here; everything
/// else about a booking is changed where it came from.
Future<void> showStayPeekSheet(
  BuildContext context, {
  required String facilityId,
  required Stay stay,
  bool canManage = false,
}) =>
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => StayPeekSheet(facilityId: facilityId, stay: stay, canManage: canManage),
    );

/// Whether the owner can take [stay] off the calendar from here: a block
/// Stays made that still holds its nights.
bool canRemoveBlock(Stay stay) => stay.isBlock && stay.isActive && stay.origin == StayOrigin.sfc && stay.sync == null;

class StayPeekSheet extends ConsumerStatefulWidget {
  const StayPeekSheet({super.key, required this.facilityId, required this.stay, this.canManage = false});

  final String facilityId;
  final Stay stay;
  final bool canManage;

  @override
  ConsumerState<StayPeekSheet> createState() => _StayPeekSheetState();
}

class _StayPeekSheetState extends ConsumerState<StayPeekSheet> {
  bool _removing = false;

  Future<void> _removeBlock() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Remove this block?'),
        content: Text('${stayDatesLabel(widget.stay.checkIn, widget.stay.checkOut)} become free in Stays.'),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Keep')),
          FilledButton(
            key: const Key('stay-block-remove-confirm'),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Remove block'),
          ),
        ],
      ),
    );
    if (ok != true || _removing || !mounted) return;
    setState(() => _removing = true);
    try {
      await ref.read(staysCallablesProvider).cancelStay(StaysCancelStayRequest(
            facilityId: widget.facilityId,
            stayId: widget.stay.id,
            expectedVersion: widget.stay.version,
            reason: 'Block removed',
          ));
      if (!mounted) return;
      showStaysSnack(context, 'Block removed.');
      Navigator.of(context).pop();
    } catch (e) {
      if (!mounted) return;
      setState(() => _removing = false);
      showStaysSnack(context, staysErrorMessage(e), error: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final stay = widget.stay;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final notes = <Widget>[];
    void note(String text, {Color? color, Key? key}) => notes.add(Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text(text, key: key, style: TextStyle(color: color ?? scheme.onSurfaceVariant)),
        ));

    if (stay.status == StayStatus.conflict) {
      final nights = describeNights(stay.conflict?.nights ?? const []);
      note(
        'Double booked${nights.isEmpty ? '' : ' on $nights'}: another booking already holds '
        '${nights.isEmpty ? 'its nights' : 'those nights'}. Cancel one of them where it was booked.',
        color: AppTheme.error,
        key: const Key('stay-peek-conflict'),
      );
    }
    if (stay.status == StayStatus.removedFromFeed) {
      note(
        '${channelProviderLabel(stay.external?.provider ?? ChannelProvider.unknown)} no longer lists this booking, '
        'so it no longer holds these nights. If the guest cancelled, nothing else is needed.',
        color: AppTheme.warning,
        key: const Key('stay-peek-removed'),
      );
    }
    if (stay.needsReview) {
      note('Stays could not tell whether this booking was cancelled. Check it on the channel.', color: AppTheme.warning);
    }
    if (stay.isFeedOwned && stay.sync?.detached != true && stay.isActive) {
      note('Its dates come from the channel: change them there, and Stays updates within about 30 minutes.');
    }
    if (stay.sync?.detached == true) note('Its calendar was removed, so this booking is no longer synced.');
    if (stay.staffNotes.trim().isNotEmpty) note('Notes: ${stay.staffNotes.trim()}');

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(stay.guestLabel, style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                StaySourceBadge(source: stay.source, kind: stay.kind),
                StayStatusChip(status: stay.status, arrivalState: stay.arrivalState),
              ],
            ),
            const SizedBox(height: 12),
            if (stay.listingName.isNotEmpty) Text(stay.listingName, style: const TextStyle(fontWeight: FontWeight.w500)),
            Text(stayDatesLabel(stay.checkIn, stay.checkOut)),
            if (stay.checkInTime.isNotEmpty && stay.checkOutTime.isNotEmpty)
              Text('Check-in ${stay.checkInTime} · checkout ${stay.checkOutTime}',
                  style: TextStyle(color: scheme.onSurfaceVariant)),
            ...notes,
            if (widget.canManage && canRemoveBlock(stay)) ...[
              const SizedBox(height: 16),
              OutlinedButton.icon(
                key: const Key('stay-block-remove'),
                onPressed: _removing ? null : _removeBlock,
                icon: const Icon(Icons.event_available),
                label: const Text('Remove block'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
